#!/usr/bin/env python3
"""Whole-layout monitor arrangement editor using GTK3 + GtkLayerShell + Cairo.

Usage: monitor-picker.py [monitor-to-preselect]

Shows ALL active monitors at their true coordinates. Any monitor (or several)
can be selected and moved — the layout is edited as a whole and applied once:

  Select    : click a monitor, Tab cycles, 1-9/0 / Ctrl+Click toggle,
              a = all/none, click empty space = clear
  Move      : plain Arrow attaches the selected monitor to the nearest
              monitor edge in that direction (any side, any arrangement);
              Alt+Arrow nudges ±25 logical px, Shift+Arrow ±1.
              Mouse drag moves freely with live edge snapping.
  Per-mon   : s/S scale ±0.1, r/R cycle refresh rate (applies to selection)
  Confirm   : Enter applies via hyprctl (caller) + persists monitors.conf;
              blocked while monitors overlap. Esc cancels.
  Extras    : e = edit raw commands, Ctrl+C = copy commands

The focused monitor is highlighted green; each box shows in real time which
workspace is active on that monitor (polled every second).

If a monitor name is given and that monitor is currently disabled (the
monitor-toggle.sh enable path), it is added at the right edge of the layout,
pre-selected and ready to move.

Outputs one hyprctl monitor config line per monitor on Enter, exits 1 on
Esc/cancel. All monitor data is queried live from wlr-randr / hyprctl.
"""

import json
import os
import re
import subprocess
import sys

import cairo

import gi
gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gdk, GLib, Gtk, GtkLayerShell

MONITORS_CONF = os.path.expanduser("~/.config/hypr/monitors.conf")

ARROW_DIRS = {"Left": "left", "Right": "right", "Up": "up", "Down": "down"}

# wlr-randr transform name -> hyprland transform number
TRANSFORMS = {
    "normal": 0, "90": 1, "180": 2, "270": 3,
    "flipped": 4, "flipped-90": 5, "flipped-180": 6, "flipped-270": 7,
}

SNAP_DRAW_PX = 16     # mouse-drag snap threshold in screen pixels
NUDGE_COARSE = 25     # Alt+Arrow step (logical px)
NUDGE_FINE = 1        # Shift+Arrow step (logical px)
SCALE_STEP = 0.1      # s/S scale step
BOX_GAP = 2           # draw-space inset so adjacent borders stay distinct

# Strip lock-key noise (NumLock, CapsLock, ScrollLock) when testing modifiers
_CLEAN_MASK = ~(
    Gdk.ModifierType.MOD2_MASK      # NumLock
    | Gdk.ModifierType.LOCK_MASK    # CapsLock
    | Gdk.ModifierType.MOD3_MASK    # ScrollLock
)

# ── external queries ──────────────────────────────────────────────────

def _query_wlr_randr():
    """Return parsed JSON from wlr-randr --json."""
    result = subprocess.run(
        ["wlr-randr", "--json"], capture_output=True, text=True, check=True
    )
    return json.loads(result.stdout)


def _query_hypr_monitors():
    """Return hyprctl monitors -j parsed, or [] if hyprctl is unavailable."""
    try:
        result = subprocess.run(
            ["hyprctl", "monitors", "-j"],
            capture_output=True, text=True, check=True,
        )
        return json.loads(result.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return []


def _query_hypr_workspaces():
    """Return hyprctl workspaces -j parsed, or [] if hyprctl is unavailable."""
    try:
        result = subprocess.run(
            ["hyprctl", "workspaces", "-j"],
            capture_output=True, text=True, check=True,
        )
        return json.loads(result.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return []


def _best_mode(monitor_entry):
    """Pick the current mode if enabled, else the first preferred mode."""
    for m in monitor_entry.get("modes", []):
        if m.get("current"):
            return m
    for m in monitor_entry.get("modes", []):
        if m.get("preferred"):
            return m
    modes = monitor_entry.get("modes", [])
    return modes[0] if modes else None


def _build_mon_info(entry):
    """Build a monitor info dict from a wlr-randr JSON entry."""
    mode = _best_mode(entry)
    pos = entry.get("position") or {"x": 0, "y": 0}
    w = mode["width"] if mode else 0
    h = mode["height"] if mode else 0
    rates = sorted({
        int(m["refresh"]) for m in entry.get("modes", [])
        if m.get("width") == w and m.get("height") == h
    }) or ([int(mode["refresh"])] if mode else [60])
    return {
        "name": entry["name"],
        "width": w,
        "height": h,
        "rate": int(mode["refresh"]) if mode else 60,
        "rates": rates,
        "scale": entry.get("scale", 1.0) or 1.0,
        "transform": TRANSFORMS.get(str(entry.get("transform", "normal")), 0),
        "x": pos.get("x", 0),
        "y": pos.get("y", 0),
        "enabled": entry.get("enabled", False),
    }


# ── geometry helpers ──────────────────────────────────────────────────

def logical_size(mon):
    """Logical pixel dimensions (res / scale), transform-aware."""
    s = mon["scale"]
    w, h = int(mon["width"] / s), int(mon["height"] / s)
    if mon.get("transform", 0) in (1, 3, 5, 7):  # 90 / 270 rotations
        w, h = h, w
    return w, h


def rects_overlap(ax, ay, aw, ah, bx, by, bw, bh):
    """Whether two rectangles share any pixel."""
    return bx < ax + aw and bx + bw > ax and by < ay + ah and by + bh > ay


def mon_rect(mon):
    return (mon["x"], mon["y"], *logical_size(mon))


def any_overlap(mons):
    """Whether any pair of monitors overlaps."""
    for i, a in enumerate(mons):
        for b in mons[i + 1:]:
            if rects_overlap(*mon_rect(a), *mon_rect(b)):
                return True
    return False


def normalized_positions(mons):
    """Return {name: (x, y)} translated so the layout starts at 0,0."""
    if not mons:
        return {}
    min_x = min(m["x"] for m in mons)
    min_y = min(m["y"] for m in mons)
    return {m["name"]: (m["x"] - min_x, m["y"] - min_y) for m in mons}


def attach_candidates(mon, others, direction):
    """Positions attaching *mon* to any side of any monitor in *others*.

    Returns (x, y) tuples where mon touches another monitor's edge facing
    *direction*, with sensible perpendicular alignments: keep the current
    position when it already lines up with that neighbor's span, plus
    edge-aligned both ways and centered. Overlapping or non-directional
    candidates are filtered by the caller.
    """
    mw, mh = logical_size(mon)
    cands = set()
    for o in others:
        ow, oh = logical_size(o)
        if direction in ("left", "right"):
            x = o["x"] + ow if direction == "right" else o["x"] - mw
            ys = {
                o["y"],                      # top edges aligned
                o["y"] + oh - mh,            # bottom edges aligned
                o["y"] + (oh - mh) // 2,     # centered
            }
            if mon["y"] < o["y"] + oh and mon["y"] + mh > o["y"]:
                ys.add(mon["y"])             # keep y — already lined up
            cands.update((x, y) for y in ys)
        else:
            y = o["y"] + oh if direction == "down" else o["y"] - mh
            xs = {
                o["x"],                      # left edges aligned
                o["x"] + ow - mw,            # right edges aligned
                o["x"] + (ow - mw) // 2,     # centered
            }
            if mon["x"] < o["x"] + ow and mon["x"] + mw > o["x"]:
                xs.add(mon["x"])             # keep x — already lined up
            cands.update((x, y) for x in xs)
    return cands


def attach_move(mon, others, direction):
    """Next non-overlapping attach position for *mon* in *direction*.

    Returns (x, y) or None if there is nowhere further in that direction.
    """
    mw, mh = logical_size(mon)
    best = None
    best_key = None
    for x, y in attach_candidates(mon, others, direction):
        if direction == "right":
            travel, perp = x - mon["x"], abs(y - mon["y"])
        elif direction == "left":
            travel, perp = mon["x"] - x, abs(y - mon["y"])
        elif direction == "down":
            travel, perp = y - mon["y"], abs(x - mon["x"])
        else:
            travel, perp = mon["y"] - y, abs(x - mon["x"])
        if travel <= 0:
            continue
        if any(rects_overlap(x, y, mw, mh, *mon_rect(o)) for o in others):
            continue
        key = (travel, perp)
        if best_key is None or key < best_key:
            best, best_key = (x, y), key
    return best


def drag_snap_delta(moving, others, s):
    """Snap adjustment (dx, dy) in logical px for a mouse drag.

    Aligns edges of the *moving* monitors to edges of *others* when within
    SNAP_DRAW_PX screen pixels (converted via draw scale *s*).
    """
    if not others or s <= 0:
        return 0, 0
    threshold = SNAP_DRAW_PX / s
    best_dx = best_dy = None
    for m in moving:
        mx, my, mw, mh = mon_rect(m)
        for o in others:
            ox, oy, ow, oh = mon_rect(o)
            for d in (ox - (mx + mw), (ox + ow) - mx,   # adjacency
                      ox - mx, (ox + ow) - (mx + mw)):  # edge alignment
                if abs(d) <= threshold and (best_dx is None or abs(d) < abs(best_dx)):
                    best_dx = d
            for d in (oy - (my + mh), (oy + oh) - my,
                      oy - my, (oy + oh) - (my + mh)):
                if abs(d) <= threshold and (best_dy is None or abs(d) < abs(best_dy)):
                    best_dy = d
    return best_dx or 0, best_dy or 0


# ── config strings & persistence ─────────────────────────────────────

def format_scale(scale):
    """Format a scale float for Hyprland config, preserving values like 1.25.

    1.0 -> '1', 1.5 -> '1.5', 1.25 -> '1.25' (float noise rounded away).
    """
    return f"{round(scale + 1e-9, 2):g}"


def mon_config_str(mon, x, y):
    """Build a Hyprland monitor config string at position x,y."""
    cfg = (
        f"{mon['name']}, {mon['width']}x{mon['height']}@{mon['rate']}, "
        f"{x}x{y}, {format_scale(mon['scale'])}"
    )
    if mon.get("transform", 0):
        cfg += f", transform, {mon['transform']}"
    return cfg


def _monitor_line_name(line):
    """Monitor name from a 'monitor = NAME, ...' config line, else None."""
    s = line.strip()
    if not s.startswith("monitor") or "=" not in s:
        return None
    return s.split("=", 1)[1].split(",")[0].strip()


def rewrite_monitors_conf(configs):
    """Rewrite monitors.conf with updated monitor lines.

    *configs* is a dict mapping monitor name -> config string. Lines matching
    those names are replaced; unmatched configs are appended. All other lines
    (comments, workspace rules, the fallback rule) are preserved.
    """
    remaining = dict(configs)
    lines = []
    if os.path.exists(MONITORS_CONF):
        with open(MONITORS_CONF) as f:
            for line in f:
                name = _monitor_line_name(line)
                if name in remaining:
                    lines.append(f"monitor = {remaining.pop(name)}\n")
                else:
                    lines.append(line)
    for cfg in remaining.values():
        lines.append(f"monitor = {cfg}\n")
    with open(MONITORS_CONF, "w") as f:
        f.writelines(lines)


# ── GTK layout editor ─────────────────────────────────────────────────

class LayoutEditor(Gtk.Window):
    def __init__(self, mons, preselect=None):
        super().__init__(title="Monitor Layout")
        self.set_app_paintable(True)
        self.set_name("omarchy.monitor-picker")

        # State — mons are mutable dicts; x/y edited in place
        self.mons = mons
        self.selected = set()
        if preselect and any(m["name"] == preselect for m in mons):
            self.selected = {preselect}
        self.focused_name = None
        self.ws_active = {}    # monitor name -> active workspace id
        self.ws_resident = {}  # monitor name -> sorted list of workspace ids
        self.edit_mode = False
        self.cmd_edited = False
        self.result = None     # tuple of config strings on confirm
        self._xform = None     # (s, ox, oy, min_x, min_y) from last draw
        self._drag = None      # (start_px, start_py, {name: (x, y)})
        self._poll_state()

        # Layer shell setup
        GtkLayerShell.init_for_window(self)
        GtkLayerShell.set_layer(self, GtkLayerShell.Layer.OVERLAY)
        GtkLayerShell.set_keyboard_mode(
            self, GtkLayerShell.KeyboardMode.EXCLUSIVE
        )
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.TOP, True)
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.BOTTOM, True)
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.LEFT, True)
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.RIGHT, True)

        # Transparency
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)

        # ── Widget tree: Overlay → DrawingArea + bottom command entry ──
        overlay = Gtk.Overlay()
        self.add(overlay)

        self.darea = Gtk.DrawingArea()
        self.darea.set_can_focus(True)
        self.darea.connect("draw", self.on_draw)
        self.darea.add_events(
            Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.POINTER_MOTION_MASK
        )
        self.darea.connect("button-press-event", self.on_button_press)
        self.darea.connect("button-release-event", self.on_button_release)
        self.darea.connect("motion-notify-event", self.on_motion)
        overlay.add(self.darea)

        # Command area — Gtk.TextView for multiline select + copy on Wayland
        cmd_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        cmd_box.set_valign(Gtk.Align.END)
        cmd_box.set_halign(Gtk.Align.CENTER)
        cmd_box.set_margin_bottom(46)

        self.cmd_prefix_label = Gtk.Label(label="Setup commands (to be run) — e: edit:")
        self.cmd_prefix_label.set_xalign(0)
        css_prefix = Gtk.CssProvider()
        css_prefix.load_from_data(
            b"label { color: rgba(255,255,255,0.5); font-size: 13px; background: transparent; }"
        )
        self.cmd_prefix_label.get_style_context().add_provider(
            css_prefix, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        self.cmd_view = Gtk.TextView()
        self.cmd_view.set_editable(False)
        self.cmd_view.set_cursor_visible(False)
        self.cmd_view.set_can_focus(True)
        self.cmd_view.set_justification(Gtk.Justification.LEFT)
        self.cmd_css = Gtk.CssProvider()
        self.cmd_css.load_from_data(
            b"textview, textview text { color: #66e6a0; font-family: monospace;"
            b"  font-size: 12px; background: transparent; caret-color: #ffcc33; }"
            b"textview text selection { background-color: #3388cc; color: white; }"
        )
        self.cmd_view.get_style_context().add_provider(
            self.cmd_css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )
        self.cmd_view.connect("key-press-event", self._on_textview_key)

        cmd_box.pack_start(self.cmd_prefix_label, False, False, 0)
        cmd_box.pack_start(self.cmd_view, False, False, 0)
        overlay.add_overlay(cmd_box)

        # Events — request key events explicitly for Wayland layer-shell
        self.add_events(Gdk.EventMask.KEY_PRESS_MASK)
        self.set_can_focus(True)
        self.connect("key-press-event", self.on_key)
        self.darea.connect("key-press-event", self.on_key)
        self.connect("destroy", Gtk.main_quit)

        # Live workspace/focus refresh
        self._poll_id = GLib.timeout_add(1000, self._on_poll)

        self.show_all()
        self.darea.grab_focus()
        self._update_cmd()

    # ── live state polling ────────────────────────────────────────────

    def _poll_state(self):
        """Refresh focused monitor + workspace residency from hyprctl.

        Rebuilds the maps from scratch so unplugged monitors don't linger;
        keeps the previous data if hyprctl momentarily returns nothing.
        """
        monitors = _query_hypr_monitors()
        if monitors:
            active = {}
            for hm in monitors:
                if hm.get("focused"):
                    self.focused_name = hm.get("name")
                active[hm.get("name")] = (hm.get("activeWorkspace") or {}).get("id")
            self.ws_active = active
        workspaces = _query_hypr_workspaces()
        if workspaces:
            resident = {}
            for ws in workspaces:
                wid = ws.get("id")
                if wid is None or wid < 0:  # skip special workspaces
                    continue
                resident.setdefault(ws.get("monitor"), []).append(wid)
            self.ws_resident = {k: sorted(v) for k, v in resident.items()}

    def _on_poll(self):
        before = (self.focused_name, dict(self.ws_active), dict(self.ws_resident))
        self._poll_state()
        if before != (self.focused_name, self.ws_active, self.ws_resident):
            self.darea.queue_draw()
        return True  # keep polling

    # ── selection helpers ─────────────────────────────────────────────

    def _selected_mons(self):
        return [m for m in self.mons if m["name"] in self.selected]

    def _unselected_mons(self):
        return [m for m in self.mons if m["name"] not in self.selected]

    def _select_next(self):
        names = [m["name"] for m in self.mons]
        if not names:
            return
        if len(self.selected) == 1:
            idx = (names.index(next(iter(self.selected))) + 1) % len(names)
        else:
            idx = 0
        self.selected = {names[idx]}

    # ── key handling ──────────────────────────────────────────────────

    def _on_textview_key(self, widget, event):
        """Intercept keys on the command textview; let copy/select-all through."""
        key = Gdk.keyval_name(event.keyval)
        ctrl = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.CONTROL_MASK)
        shift = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.SHIFT_MASK)
        if self.edit_mode:
            if key == "Escape":
                self._exit_edit_mode()
                return True
            if ctrl and key in ("Return", "KP_Enter"):
                return self.on_key(widget, event)
            return False
        if ctrl and key in ("c", "C", "a", "A"):
            return False
        if shift and key in ("Left", "Right", "Up", "Down"):
            return self.on_key(widget, event)
        if key in ("Home", "End"):
            return False
        return self.on_key(widget, event)

    def on_key(self, widget, event):
        key = Gdk.keyval_name(event.keyval)
        ctrl = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.CONTROL_MASK)

        if key == "Escape":
            if self.edit_mode:
                self._exit_edit_mode()
                return True
            Gtk.main_quit()
            return True

        # In edit mode, let the textview handle everything except Ctrl+Enter
        if self.edit_mode and widget is not self.cmd_view:
            if not (ctrl and key in ("Return", "KP_Enter")):
                return False

        if key in ("Return", "KP_Enter"):
            return self._confirm()

        # Ctrl+C from anywhere: copy commands to Wayland clipboard via wl-copy
        if ctrl and key in ("c", "C"):
            cmd = " && ".join(self._build_display_cmd().splitlines())
            try:
                subprocess.Popen(
                    ["wl-copy", cmd],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            except FileNotFoundError:
                pass
            return True

        # Arrows — plain: attach-move; Alt: ±25 nudge; Shift: ±1 nudge
        if key in ARROW_DIRS:
            direction = ARROW_DIRS[key]
            alt = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.MOD1_MASK)
            shift = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.SHIFT_MASK)
            sel = self._selected_mons()
            if not sel:
                return True
            if alt or shift:
                step = NUDGE_FINE if shift else NUDGE_COARSE
                dx = {"left": -step, "right": step}.get(direction, 0)
                dy = {"up": -step, "down": step}.get(direction, 0)
                for m in sel:
                    m["x"] += dx
                    m["y"] += dy
            elif len(sel) == 1:
                dest = attach_move(sel[0], self._unselected_mons(), direction)
                if dest:
                    sel[0]["x"], sel[0]["y"] = dest
            else:
                # group attach is ambiguous — move the group coarsely instead
                dx = {"left": -NUDGE_COARSE, "right": NUDGE_COARSE}.get(direction, 0)
                dy = {"up": -NUDGE_COARSE, "down": NUDGE_COARSE}.get(direction, 0)
                for m in sel:
                    m["x"] += dx
                    m["y"] += dy
            self._layout_changed()
            return True

        # Tab — cycle single selection
        if key in ("Tab", "ISO_Left_Tab"):
            self._select_next()
            self.darea.queue_draw()
            return True

        # 1-9, 0 — toggle selection of monitor by displayed index (0 = 10th)
        if key.isdigit():
            idx = 9 if key == "0" else int(key) - 1
            if idx < len(self.mons):
                name = self.mons[idx]["name"]
                self.selected.symmetric_difference_update({name})
                self.darea.queue_draw()
            return True

        # a — select all / clear
        if key == "a":
            if len(self.selected) == len(self.mons):
                self.selected = set()
            else:
                self.selected = {m["name"] for m in self.mons}
            self.darea.queue_draw()
            return True

        # s / S — adjust scale of selected monitors by ±SCALE_STEP
        if key in ("s", "S"):
            delta = SCALE_STEP if key == "s" else -SCALE_STEP
            for m in self._selected_mons():
                m["scale"] = max(0.5, min(5.0, round(m["scale"] + delta, 2)))
            self._layout_changed()
            return True

        # r / R — cycle available refresh rates of selected monitors
        if key in ("r", "R"):
            step = 1 if key == "r" else -1
            for m in self._selected_mons():
                rates = m.get("rates") or [m["rate"]]
                try:
                    i = rates.index(m["rate"])
                except ValueError:
                    i = len(rates) - 1
                m["rate"] = rates[max(0, min(len(rates) - 1, i + step))]
            self._layout_changed()
            return True

        # e — enter edit mode (direct text editing of the setup commands)
        if key == "e":
            self._enter_edit_mode()
            return True

        return False

    def _confirm(self):
        if self.cmd_edited:
            configs = self._parse_edited_cmd()
            if not configs:
                return True  # unparseable — ignore Enter
        else:
            if any_overlap(self.mons):
                return True  # overlap warning is on screen; refuse to apply
            norm = normalized_positions(self.mons)
            configs = [mon_config_str(m, *norm[m["name"]]) for m in self.mons]
        self.result = tuple(configs)
        rewrite_monitors_conf({c.split(",", 1)[0].strip(): c for c in configs})
        Gtk.main_quit()
        return True

    def _layout_changed(self):
        self.darea.queue_draw()
        self._update_cmd()

    # ── mouse handling ────────────────────────────────────────────────

    def _mon_at(self, px, py):
        """Monitor under screen point (px, py), or None."""
        if not self._xform:
            return None
        s, ox, oy, min_x, min_y = self._xform
        lx = (px - ox) / s + min_x
        ly = (py - oy) / s + min_y
        for m in reversed(self.mons):  # later-drawn (selected) on top
            x, y, w, h = mon_rect(m)
            if x <= lx < x + w and y <= ly < y + h:
                return m
        return None

    def on_button_press(self, widget, event):
        if event.button != 1 or self.edit_mode:
            return False
        self.darea.grab_focus()
        mon = self._mon_at(event.x, event.y)
        ctrl = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.CONTROL_MASK)
        if mon is None:
            self.selected = set()
            self.darea.queue_draw()
            return True
        if ctrl:
            self.selected.symmetric_difference_update({mon["name"]})
        elif mon["name"] not in self.selected:
            self.selected = {mon["name"]}
        if mon["name"] in self.selected:
            self._drag = (
                event.x, event.y,
                {m["name"]: (m["x"], m["y"]) for m in self._selected_mons()},
            )
        self.darea.queue_draw()
        return True

    def on_motion(self, widget, event):
        if not self._drag or not self._xform:
            return False
        s = self._xform[0]
        sx, sy, orig = self._drag
        dx = (event.x - sx) / s
        dy = (event.y - sy) / s
        # Only monitors that were selected when the drag started have an
        # origin — selection can change mid-drag via keyboard.
        moving = [m for m in self._selected_mons() if m["name"] in orig]
        if not moving:
            return True
        for m in moving:
            ox_, oy_ = orig[m["name"]]
            m["x"] = round(ox_ + dx)
            m["y"] = round(oy_ + dy)
        snap_dx, snap_dy = drag_snap_delta(moving, self._unselected_mons(), s)
        for m in moving:
            m["x"] += snap_dx
            m["y"] += snap_dy
        self._layout_changed()
        return True

    def on_button_release(self, widget, event):
        if event.button == 1 and self._drag:
            self._drag = None
            self._layout_changed()
            return True
        return False

    # ── edit mode ─────────────────────────────────────────────────────

    def _enter_edit_mode(self):
        """Enable direct editing of the command textview."""
        self.edit_mode = True
        buf = self.cmd_view.get_buffer()
        buf.set_text(self._build_display_cmd())
        self.cmd_view.set_editable(True)
        self.cmd_view.set_cursor_visible(True)
        self.cmd_prefix_label.set_text(
            "Editing setup commands — Esc: done  ·  Ctrl+Enter: confirm:"
        )
        self.cmd_view.grab_focus()
        buf.place_cursor(buf.get_end_iter())

    def _exit_edit_mode(self):
        """Leave edit mode; preserve the edited buffer as authoritative."""
        self.edit_mode = False
        self.cmd_edited = True
        self.cmd_view.set_editable(False)
        self.cmd_view.set_cursor_visible(False)
        self.cmd_prefix_label.set_text(
            "Setup commands (edited — Enter to apply, any layout key to regenerate):"
        )
        self.darea.grab_focus()

    def _parse_edited_cmd(self):
        """Extract quoted monitor config strings from the edited textview."""
        buf = self.cmd_view.get_buffer()
        text = buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)
        configs = []
        for line in text.splitlines():
            m = re.search(r'hyprctl\s+keyword\s+monitor\s+"([^"]+)"', line.strip())
            if m:
                configs.append(m.group(1))
        return configs

    # ── command display ───────────────────────────────────────────────

    def _build_display_cmd(self):
        """Shell commands applying the whole (normalized) layout."""
        norm = normalized_positions(self.mons)
        return "\n".join(
            f'hyprctl keyword monitor "{mon_config_str(m, *norm[m["name"]])}"'
            for m in self.mons
        )

    def _update_cmd(self):
        """Refresh the command textview text and color."""
        if self.edit_mode:
            return
        if self.cmd_edited:
            self.cmd_edited = False
            self.cmd_prefix_label.set_text("Setup commands (to be run) — e: edit:")
        color = "#ff5a4d" if any_overlap(self.mons) else "#66e6a0"
        self.cmd_css.load_from_data(
            f"textview, textview text {{ color: {color}; font-family: monospace;"
            f"  font-size: 12px; background: transparent; caret-color: #ffcc33; }}"
            f"textview text selection {{ background-color: #3388cc; color: white; }}"
            .encode()
        )
        self.cmd_view.get_buffer().set_text(self._build_display_cmd())

    # ── drawing ───────────────────────────────────────────────────────

    def on_draw(self, widget, cr):
        alloc = widget.get_allocation()
        sw, sh = alloc.width, alloc.height

        # Background
        cr.set_source_rgba(0.05, 0.05, 0.1, 0.88)
        cr.rectangle(0, 0, sw, sh)
        cr.fill()

        if not self.mons:
            return

        # True-coordinate layout scaled to fit
        rects = [mon_rect(m) for m in self.mons]
        min_x = min(r[0] for r in rects)
        min_y = min(r[1] for r in rects)
        span_w = max(max(r[0] + r[2] for r in rects) - min_x, 1)
        span_h = max(max(r[1] + r[3] for r in rects) - min_y, 1)
        s = min(sw * 0.62 / span_w, sh * 0.48 / span_h)
        ox = (sw - span_w * s) / 2
        oy = (sh * 0.80 - span_h * s) / 2  # keep clear of the bottom info area
        self._xform = (s, ox, oy, min_x, min_y)

        def draw_box(x, y, w, h):
            return (ox + (x - min_x) * s + BOX_GAP, oy + (y - min_y) * s + BOX_GAP,
                    w * s - 2 * BOX_GAP, h * s - 2 * BOX_GAP)

        # Unselected first, selected on top
        ordered = self._unselected_mons() + self._selected_mons()
        for m in ordered:
            self._draw_monitor_box(cr, *draw_box(*mon_rect(m)), m)

        # Alignment guide lines between selected and unselected monitors
        for m in self._selected_mons():
            for o in self._unselected_mons():
                self._draw_snap_lines(cr, draw_box(*mon_rect(o)), draw_box(*mon_rect(m)))

        # --- Bottom info area (drawn upward from bottom) ---
        cr.select_font_face("Sans", 0, 0)
        bottom_y = sh - 30

        # Row 1 (lowest): hint bar
        hint = ("Click/drag: select+move  ·  Ctrl+Click / 1-9/0: multi-select  ·  Tab: next  ·  a: all/none"
                "  ·  Arrows: attach  ·  Alt/Shift+Arrow: nudge ±25/±1  ·  s/S: scale  ·  r/R: rate"
                "  ·  e: edit cmd  ·  Ctrl+C: copy  ·  Enter: apply  ·  Esc: cancel")
        cr.set_source_rgba(1, 1, 1, 0.45)
        cr.set_font_size(14)
        te = cr.text_extents(hint)
        cr.move_to((sw - te.width) / 2, bottom_y)
        cr.show_text(hint)

        # Row 2: command textview (GTK widget) — skip past it
        bottom_y = sh - 120 - 14 * max(0, len(self.mons) - 2)

        # Row 3: overlap warning
        if any_overlap(self.mons):
            warn = "Monitors overlap — Enter disabled until resolved"
            cr.set_source_rgba(1.0, 0.35, 0.3, 0.9)
            cr.set_font_size(17)
            te = cr.text_extents(warn)
            cr.move_to((sw - te.width) / 2, bottom_y)
            cr.show_text(warn)
            bottom_y -= 28

        # Row 4 (topmost): selection summary
        sel = ", ".join(sorted(self.selected)) or "none — click a monitor or press Tab"
        label = f"Selected: {sel}"
        cr.set_source_rgba(1, 1, 1, 0.7)
        cr.set_font_size(18)
        te = cr.text_extents(label)
        cr.move_to((sw - te.width) / 2, bottom_y)
        cr.show_text(label)

    def _draw_monitor_box(self, cr, x, y, w, h, mon):
        name = mon["name"]
        is_sel = name in self.selected
        is_focused = name == self.focused_name

        # Fill — selected boxes get a subtle tint
        if is_sel:
            cr.set_source_rgba(0.13, 0.22, 0.30, 0.95)
        else:
            cr.set_source_rgba(0.15, 0.15, 0.2, 0.9)
        cr.rectangle(x, y, w, h)
        cr.fill()

        # Border — selected: cyan (thick); focused: green; both: cyan + green inner ring
        if is_sel:
            cr.set_source_rgba(0.2, 0.8, 1.0, 1.0)
            cr.set_line_width(4)
        elif is_focused:
            cr.set_source_rgba(0.4, 0.8, 0.4, 1.0)
            cr.set_line_width(3)
        else:
            cr.set_source_rgba(0.45, 0.45, 0.5, 1.0)
            cr.set_line_width(2.5)
        cr.rectangle(x, y, w, h)
        cr.stroke()
        if is_sel and is_focused:
            cr.set_source_rgba(0.4, 0.8, 0.4, 1.0)
            cr.set_line_width(2)
            cr.rectangle(x + 4, y + 4, w - 8, h - 8)
            cr.stroke()

        # Index tag (for digit-key selection) + focus marker, top-left corner
        idx = next((i for i, m in enumerate(self.mons) if m is mon), 0) + 1
        tag = f"[{idx}]" + ("  focused" if is_focused else "")
        cr.set_source_rgba(1, 1, 1, 0.55)
        cr.select_font_face("Sans", 0, 0)
        cr.set_font_size(12)
        cr.move_to(x + 8, y + 18)
        cr.show_text(tag)

        # Monitor name
        cr.set_source_rgba(1, 1, 1, 0.95)
        cr.set_font_size(min(w * 0.10, 20))
        te = cr.text_extents(name)
        cr.move_to(x + (w - te.width) / 2, y + h * 0.30)
        cr.show_text(name)

        # Active workspace (live)
        ws = self.ws_active.get(name)
        if ws is not None:
            ws_label = f"ws {ws}"
            cr.set_source_rgba(1.0, 0.8, 0.2, 0.95)
            cr.set_font_size(min(w * 0.13, 26))
            te = cr.text_extents(ws_label)
            cr.move_to(x + (w - te.width) / 2, y + h * 0.50)
            cr.show_text(ws_label)
        resident = self.ws_resident.get(name)
        if resident:
            res_label = "workspaces: " + " ".join(str(i) for i in resident)
            cr.set_source_rgba(1.0, 0.8, 0.2, 0.5)
            cr.set_font_size(min(w * 0.05, 12))
            te = cr.text_extents(res_label)
            cr.move_to(x + (w - te.width) / 2, y + h * 0.60)
            cr.show_text(res_label)

        # Resolution / rate
        res = f"{mon['width']}x{mon['height']}@{mon['rate']}Hz"
        cr.set_source_rgba(1, 1, 1, 0.85)
        cr.set_font_size(min(w * 0.07, 14))
        te = cr.text_extents(res)
        cr.move_to(x + (w - te.width) / 2, y + h * 0.74)
        cr.show_text(res)

        # Scale / logical size / position
        lw, lh = logical_size(mon)
        detail = (f"scale {format_scale(mon['scale'])}  ·  "
                  f"{lw}x{lh} logical  ·  at {mon['x']},{mon['y']}")
        cr.set_source_rgba(1, 1, 1, 0.4)
        cr.set_font_size(min(w * 0.05, 11))
        te = cr.text_extents(detail)
        cr.move_to(x + (w - te.width) / 2, y + h * 0.86)
        cr.show_text(detail)

    def _draw_snap_lines(self, cr, box_a, box_b):
        """Draw guide lines where edges of two draw-space boxes coincide."""
        ax, ay, aw, ah = box_a
        bx, by, bw, bh = box_b
        tolerance = 2 * BOX_GAP + 1.5  # inset on both boxes + slack
        extend = 40

        # Horizontal edges (y-coordinates)
        y_pairs = [(ay, by), (ay + ah, by + bh), (ay + ah, by), (ay, by + bh)]
        y_aligned = [
            (e1 + e2) / 2 for e1, e2 in y_pairs if abs(e1 - e2) <= tolerance
        ]
        if y_aligned:
            left = min(ax, bx) - extend
            right = max(ax + aw, bx + bw) + extend
            mid_l = min(ax, bx)
            mid_r = max(ax + aw, bx + bw)
            span = right - left if right != left else 1
            cr.save()
            for sy in dict.fromkeys(y_aligned):
                pat = cairo.LinearGradient(left, sy, right, sy)
                pat.add_color_stop_rgba(0, 0.6, 0.6, 0.6, 0)
                pat.add_color_stop_rgba((mid_l - left) / span, 0.6, 0.6, 0.6, 0.5)
                pat.add_color_stop_rgba((mid_r - left) / span, 0.6, 0.6, 0.6, 0.5)
                pat.add_color_stop_rgba(1, 0.6, 0.6, 0.6, 0)
                cr.set_source(pat)
                cr.set_line_width(1.5)
                cr.move_to(left, sy)
                cr.line_to(right, sy)
                cr.stroke()
            cr.restore()

        # Vertical edges (x-coordinates)
        x_pairs = [(ax, bx), (ax + aw, bx + bw), (ax + aw, bx), (ax, bx + bw)]
        x_aligned = [
            (e1 + e2) / 2 for e1, e2 in x_pairs if abs(e1 - e2) <= tolerance
        ]
        if x_aligned:
            top = min(ay, by) - extend
            bottom = max(ay + ah, by + bh) + extend
            mid_t = min(ay, by)
            mid_b = max(ay + ah, by + bh)
            span = bottom - top if bottom != top else 1
            cr.save()
            for sx in dict.fromkeys(x_aligned):
                pat = cairo.LinearGradient(sx, top, sx, bottom)
                pat.add_color_stop_rgba(0, 0.6, 0.6, 0.6, 0)
                pat.add_color_stop_rgba((mid_t - top) / span, 0.6, 0.6, 0.6, 0.5)
                pat.add_color_stop_rgba((mid_b - top) / span, 0.6, 0.6, 0.6, 0.5)
                pat.add_color_stop_rgba(1, 0.6, 0.6, 0.6, 0)
                cr.set_source(pat)
                cr.set_line_width(1.5)
                cr.move_to(sx, top)
                cr.line_to(sx, bottom)
                cr.stroke()
            cr.restore()


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else None

    entries = _query_wlr_randr()
    mons = [
        _build_mon_info(e) for e in entries
        if e.get("enabled") or e["name"] == target
    ]
    if not mons:
        print("No monitors found", file=sys.stderr)
        sys.exit(1)
    if target and not any(m["name"] == target for m in mons):
        print(f"Unknown monitor: {target}", file=sys.stderr)
        sys.exit(1)

    # A disabled preselect target is being enabled: give it a starting spot
    # at the right edge of the current layout.
    for m in mons:
        if m["name"] == target and not m["enabled"]:
            others = [o for o in mons if o["enabled"]]
            if others:
                m["x"] = max(o["x"] + logical_size(o)[0] for o in others)
                m["y"] = min(o["y"] for o in others)
            m["enabled"] = True

    # Default selection: the given target, else the focused monitor
    preselect = target
    if not preselect:
        for hm in _query_hypr_monitors():
            if hm.get("focused"):
                preselect = hm.get("name")
                break

    editor = LayoutEditor(mons, preselect)
    Gtk.main()

    if editor.result:
        for cfg in editor.result:
            print(cfg)
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
