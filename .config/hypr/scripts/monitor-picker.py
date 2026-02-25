#!/usr/bin/env python3
"""Interactive monitor placement picker using GTK3 + GtkLayerShell + Cairo.

Usage: monitor-picker.py <monitor-to-place>
Outputs TWO hyprctl monitor config lines on Enter (current + new), exits 1 on
Esc/cancel. On confirm, also rewrites ~/.config/hypr/monitors.conf to persist.
All monitor data is queried live from wlr-randr (no hardcoded values).
"""

import json
import os
import subprocess
import sys

import cairo

import gi
gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gdk, Gtk, GtkLayerShell

POSITIONS = ["below", "right", "above", "left"]
POS_MAP = {"Right": "right", "Left": "left", "Up": "below", "Down": "above"}

MONITORS_CONF = os.path.expanduser("~/.config/hypr/monitors.conf")

# Strip lock-key noise (NumLock, CapsLock, ScrollLock) when testing modifiers
_CLEAN_MASK = ~(
    Gdk.ModifierType.MOD2_MASK      # NumLock
    | Gdk.ModifierType.LOCK_MASK    # CapsLock
    | Gdk.ModifierType.MOD3_MASK    # ScrollLock
)

# ── wlr-randr helpers ─────────────────────────────────────────────────

def _query_wlr_randr():
    """Return parsed JSON from wlr-randr --json."""
    result = subprocess.run(
        ["wlr-randr", "--json"], capture_output=True, text=True, check=True
    )
    return json.loads(result.stdout)


def _icon_for(name):
    """Guess a display icon from the connector name."""
    n = name.lower()
    if n.startswith("edp"):
        return "\U0001f4bb"   # laptop
    if n.startswith("hdmi"):
        return "\U0001f4fa"   # TV
    return "\U0001f5b5"       # generic display


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
    pos = entry.get("position", {"x": 0, "y": 0})
    phys = entry.get("physical_size", {})
    return {
        "name": entry["name"],
        "width": mode["width"] if mode else 0,
        "height": mode["height"] if mode else 0,
        "rate": int(mode["refresh"]) if mode else 60,
        "scale": entry.get("scale", 1.0),
        "x": pos.get("x", 0),
        "y": pos.get("y", 0),
        "phys_w": phys.get("width", 0),
        "phys_h": phys.get("height", 0),
        "icon": _icon_for(entry["name"]),
        "enabled": entry.get("enabled", False),
    }


def get_all_monitors():
    """Return list of monitor info dicts for every connected output."""
    return [_build_mon_info(e) for e in _query_wlr_randr()]


def get_active_monitor(exclude_name):
    """Get the first active monitor that isn't *exclude_name*."""
    for m in get_all_monitors():
        if m["enabled"] and m["name"] != exclude_name:
            return m
    return None


def get_monitor_by_name(name):
    """Get a specific monitor by connector name."""
    for m in get_all_monitors():
        if m["name"] == name:
            return m
    return None

# ── geometry helpers ──────────────────────────────────────────────────

def logical_size(mon):
    """Logical pixel dimensions (res / scale), truncated to integers like Hyprland."""
    s = mon["scale"]
    return int(mon["width"] / s), int(mon["height"] / s)


def monitors_overlap(current, new_x, new_y, new_mon):
    """Check whether two monitor rectangles share any pixel."""
    aw, ah = logical_size(current)
    ax, ay = current["x"], current["y"]
    bw, bh = logical_size(new_mon)
    bx, by = new_x, new_y
    return bx < ax + aw and bx + bw > ax and by < ay + ah and by + bh > ay


def calc_hypr_position(position, current, new, offset=0):
    """Calculate Hyprland position coordinates for the new monitor.

    *offset* shifts the new monitor on the perpendicular axis (logical px).
    For left/right positions it shifts vertically; for above/below horizontally.
    """
    cw, ch = logical_size(current)
    nw, nh = logical_size(new)
    cx, cy = current["x"], current["y"]
    if position == "right":
        return int(cx + cw), int(cy + offset)
    elif position == "left":
        return int(cx - nw), int(cy + offset)
    elif position == "below":
        return int(cx + offset), int(cy + ch)
    elif position == "above":
        return int(cx + offset), int(cy - nh)


def _format_scale(scale_tenths):
    """Format an integer-tenths scale value for Hyprland config.

    20 → '2', 24 → '2.4', 15 → '1.5'
    """
    if scale_tenths % 10 == 0:
        return str(scale_tenths // 10)
    return f"{scale_tenths / 10:.1f}"


def _mon_config_str(mon, x=None, y=None, scale_tenths=None):
    """Build a Hyprland monitor config string for a monitor dict."""
    mx = x if x is not None else mon["x"]
    my = y if y is not None else mon["y"]
    st = scale_tenths if scale_tenths is not None else _scale_tenths_from(mon)
    return f"{mon['name']}, {mon['width']}x{mon['height']}@{mon['rate']}, {mx}x{my}, {_format_scale(st)}"


# ── arithmetic expression helpers ────────────────────────────────────

def _scale_div_expr(value, scale_tenths):
    """Bash $(( )) expression for value / scale using integer-tenths.

    Avoids floating point by scaling up by 10:
      scale_tenths=20  (scale 2):    '2560 / 2'
      scale_tenths=21  (scale 2.1):  '2560 * 10 / 21'
      scale_tenths=24  (scale 2.4):  '3840 * 10 / 24'
    """
    if scale_tenths % 10 == 0:
        return f"{value} / {scale_tenths // 10}"
    return f"{value} * 10 / {scale_tenths}"


def _scale_tenths_from(mon):
    """Convert a monitor's scale float to integer tenths."""
    return round(mon["scale"] * 10)


def _build_pos_exprs(position, current, new, offset=0, new_scale_tenths=None):
    """Return (x_expr, y_expr) as bash $(( )) strings showing the math."""
    cx, cy = current["x"], current["y"]
    cw, ch = current["width"], current["height"]
    cs = _scale_tenths_from(current)
    nw, nh = new["width"], new["height"]
    ns = new_scale_tenths if new_scale_tenths is not None else _scale_tenths_from(new)

    def _add(base, extra_expr):
        if base == 0:
            return extra_expr
        return f"{base} + ({extra_expr})"

    def _sub(base, extra_expr):
        if base == 0:
            return f"0 - ({extra_expr})"
        return f"{base} - ({extra_expr})"

    def _with_offset(val, off):
        if off == 0:
            return str(val)
        if off > 0:
            return f"{val} + {off}"
        return f"{val} - {abs(off)}"

    if position == "right":
        x = f"$(({_add(cx, _scale_div_expr(cw, cs))}))"
        y = f"$(({_with_offset(cy, offset)}))"
    elif position == "left":
        x = f"$(({_sub(cx, _scale_div_expr(nw, ns))}))"
        y = f"$(({_with_offset(cy, offset)}))"
    elif position == "below":
        x = f"$(({_with_offset(cx, offset)}))"
        y = f"$(({_add(cy, _scale_div_expr(ch, cs))}))"
    elif position == "above":
        x = f"$(({_with_offset(cx, offset)}))"
        y = f"$(({_sub(cy, _scale_div_expr(nh, ns))}))"
    return x, y


# ── monitors.conf persistence ────────────────────────────────────────

def rewrite_monitors_conf(configs):
    """Rewrite monitors.conf with updated monitor lines.

    *configs* is a dict mapping monitor name → config string.
    Lines matching those names are replaced; unmatched configs are appended.
    All other lines (comments, env, unrelated monitors) are preserved.
    """
    remaining = dict(configs)
    lines = []
    if os.path.exists(MONITORS_CONF):
        with open(MONITORS_CONF) as f:
            for line in f:
                stripped = line.strip()
                replaced = False
                if stripped.startswith("monitor"):
                    for name, cfg in list(remaining.items()):
                        if f"= {name}" in stripped or f"= {name}," in stripped:
                            lines.append(f"monitor = {cfg}\n")
                            del remaining[name]
                            replaced = True
                            break
                if not replaced:
                    lines.append(line)
    for cfg in remaining.values():
        lines.append(f"monitor = {cfg}\n")
    with open(MONITORS_CONF, "w") as f:
        f.writelines(lines)


# ── GTK picker ────────────────────────────────────────────────────────

class MonitorPicker(Gtk.Window):
    def __init__(self, current, new_mon):
        super().__init__(title="Monitor Picker")
        self.set_app_paintable(True)
        self.set_name("omarchy.monitor-picker")

        # State
        self.current = current
        self.new_mon = new_mon
        self.pos_index = 1  # start at "right"
        self.offset = 0     # perpendicular offset in logical pixels
        self.new_scale_tenths = _scale_tenths_from(new_mon)  # integer: scale * 10
        self.orig_scale_tenths = self.new_scale_tenths
        self.result = None   # will hold (current_config, new_config) on confirm

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

        # Drawing area (base layer — draws everything except the command)
        self.darea = Gtk.DrawingArea()
        self.darea.set_can_focus(True)
        self.darea.connect("draw", self.on_draw)
        overlay.add(self.darea)

        # Command area — Gtk.TextView for multiline select + copy on Wayland
        cmd_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        cmd_box.set_valign(Gtk.Align.END)
        cmd_box.set_halign(Gtk.Align.CENTER)
        cmd_box.set_margin_bottom(46)

        self.cmd_prefix_label = Gtk.Label(label="Setup commands (to be run):")
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
            b"  font-size: 12px; background: transparent; }"
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

        self.show_all()
        self.darea.grab_focus()
        self._update_cmd()

    @property
    def position(self):
        return POSITIONS[self.pos_index]

    # ── Key handling ──────────────────────────────────────────────────

    def _on_textview_key(self, widget, event):
        """Intercept keys on the command textview; let copy/select-all through."""
        key = Gdk.keyval_name(event.keyval)
        ctrl = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.CONTROL_MASK)
        shift = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.SHIFT_MASK)
        # Let the textview handle Ctrl+C, Ctrl+A, and Shift+Arrow for selection
        # (but NOT Shift+Arrow when it's a fine-tune key — forward those to on_key)
        if ctrl and key in ("c", "C", "a", "A"):
            return False
        if shift and key in ("Left", "Right", "Up", "Down"):
            # Shift+Arrow is fine-tune ±1; forward to on_key, not the textview
            return self.on_key(widget, event)
        if shift and key in ("Home", "End"):
            return False
        if key in ("Home", "End"):
            return False
        return self.on_key(widget, event)

    def on_key(self, widget, event):
        key = Gdk.keyval_name(event.keyval)
        ctrl = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.CONTROL_MASK)

        if key == "Escape":
            Gtk.main_quit()
            return True

        if key in ("Return", "KP_Enter"):
            cur_cfg = _mon_config_str(self.current)
            new_cfg = self._new_config_str()
            self.result = (cur_cfg, new_cfg)
            rewrite_monitors_conf({
                self.current["name"]: cur_cfg,
                self.new_mon["name"]: new_cfg,
            })
            Gtk.main_quit()
            return True

        # Ctrl+C from anywhere: copy command to Wayland clipboard via wl-copy
        if ctrl and key in ("c", "C"):
            # Join lines with && for a runnable one-liner
            cmd = " && ".join(self._build_display_cmd().splitlines())
            try:
                subprocess.Popen(
                    ["wl-copy", cmd],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
            except FileNotFoundError:
                pass
            return True

        # Arrow keys — check key first, THEN test modifier.
        # Three tiers: plain=position, Alt=±25 with snap, Shift=±1 no snap
        if key in POS_MAP:
            alt = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.MOD1_MASK)
            shift = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.SHIFT_MASK)
            if alt or shift:
                pos = self.position
                step = 1 if shift else 25
                is_offset_key = (
                    (pos in ("right", "left") and key in ("Up", "Down"))
                    or (pos in ("above", "below") and key in ("Left", "Right"))
                )
                if is_offset_key:
                    positive = key in ("Down", "Right")
                    delta = step if positive else -step
                    new_offset = self.offset + delta
                    if not shift:  # snap only for Alt+Arrow (±25), not Shift (±1)
                        new_offset = self._snap_offset(self.offset, new_offset, delta > 0)
                    self.offset = new_offset
            else:
                self.pos_index = POSITIONS.index(POS_MAP[key])
                self.offset = 0
            self._sync_scale()
            self.darea.queue_draw()
            self._update_cmd()
            return True

        # s / S — adjust scale of the new monitor by ±0.1
        if key == "s":
            self.new_scale_tenths = max(5, self.new_scale_tenths - 1)
            self._sync_scale()
            self.darea.queue_draw()
            self._update_cmd()
            return True
        if key == "S":
            self.new_scale_tenths = min(50, self.new_scale_tenths + 1)
            self._sync_scale()
            self.darea.queue_draw()
            self._update_cmd()
            return True

        return False

    def _sync_scale(self):
        """Keep new_mon['scale'] in sync with new_scale_tenths for geometry calcs."""
        self.new_mon["scale"] = self.new_scale_tenths / 10.0

    # ── Snap alignment helpers ────────────────────────────────────────

    def _snap_offsets(self):
        """Return sorted offsets where monitor edges visually coincide.

        The visual layout centers both boxes, so logical alignment (offset=0)
        does NOT produce visually aligned edges when monitors differ in size.
        These snap points compensate for the centering offset so edges actually
        line up on screen.
        """
        ch_nat = self.current["height"]
        nh_nat = self.new_mon["height"]
        cw_nat = self.current["width"]
        nw_nat = self.new_mon["width"]
        cs = self.current["scale"]
        pos = self.position
        if pos in ("right", "left"):
            points = {
                round((nh_nat - ch_nat) / (2 * cs)),    # top-top
                round((ch_nat - nh_nat) / (2 * cs)),    # bottom-bottom
                round((nh_nat + ch_nat) / (2 * cs)),    # cur-bottom = new-top
                round(-(nh_nat + ch_nat) / (2 * cs)),   # cur-top = new-bottom
            }
        else:
            points = {
                round((nw_nat - cw_nat) / (2 * cs)),    # left-left
                round((cw_nat - nw_nat) / (2 * cs)),    # right-right
                round((nw_nat + cw_nat) / (2 * cs)),    # cur-right = new-left
                round(-(nw_nat + cw_nat) / (2 * cs)),   # cur-left = new-right
            }
        return sorted(points)

    def _snap_offset(self, old, new, moving_positive):
        """Snap new offset to alignment point if one was crossed."""
        snaps = self._snap_offsets()
        if moving_positive:
            # Find smallest snap > old and <= new
            candidates = [s for s in snaps if s > old and s <= new]
            return min(candidates) if candidates else new
        else:
            # Find largest snap < old and >= new
            candidates = [s for s in snaps if s < old and s >= new]
            return max(candidates) if candidates else new

    def _draw_snap_lines(self, cr, cur_x, cur_y, cur_bw, cur_bh,
                         new_x, new_y, new_bw, new_bh):
        """Draw guide lines where monitor edges visually coincide.

        Checks all pairs of corresponding edges (top/bottom or left/right)
        and draws a line only when a current-monitor edge and a new-monitor
        edge are at the same screen coordinate (within a small tolerance).
        """
        pos = self.position
        tolerance = 1.5  # visual pixels
        extend = 40

        if pos in ("right", "left"):
            # Horizontal edge pairs (y-coordinates)
            pairs = [
                (cur_y, new_y),                          # top-top
                (cur_y + cur_bh, new_y + new_bh),        # bottom-bottom
                (cur_y + cur_bh, new_y),                  # cur-bottom = new-top
                (cur_y, new_y + new_bh),                  # cur-top = new-bottom
            ]
            aligned = []
            for e1, e2 in pairs:
                if abs(e1 - e2) <= tolerance:
                    aligned.append((e1 + e2) / 2)
            if not aligned:
                return

            cr.save()
            left = min(cur_x, new_x) - extend
            right = max(cur_x + cur_bw, new_x + new_bw) + extend
            mid_l = min(cur_x, new_x)
            mid_r = max(cur_x + cur_bw, new_x + new_bw)
            span = right - left if right != left else 1

            for sy in dict.fromkeys(aligned):
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
        else:
            # Vertical edge pairs (x-coordinates)
            pairs = [
                (cur_x, new_x),                          # left-left
                (cur_x + cur_bw, new_x + new_bw),        # right-right
                (cur_x + cur_bw, new_x),                  # cur-right = new-left
                (cur_x, new_x + new_bw),                  # cur-left = new-right
            ]
            aligned = []
            for e1, e2 in pairs:
                if abs(e1 - e2) <= tolerance:
                    aligned.append((e1 + e2) / 2)
            if not aligned:
                return

            cr.save()
            top = min(cur_y, new_y) - extend
            bottom = max(cur_y + cur_bh, new_y + new_bh) + extend
            mid_t = min(cur_y, new_y)
            mid_b = max(cur_y + cur_bh, new_y + new_bh)
            span = bottom - top if bottom != top else 1

            for sx in dict.fromkeys(aligned):
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

    # ── Config / command helpers ──────────────────────────────────────

    def _new_config_str(self):
        """Config string for the new monitor at its calculated position."""
        x, y = calc_hypr_position(self.position, self.current, self.new_mon, self.offset)
        return _mon_config_str(self.new_mon, x, y, self.new_scale_tenths)

    def _build_display_cmd(self):
        """Build a shell-evaluable command setting BOTH monitors, with $(( ))."""
        c = self.current
        n = self.new_mon
        x_expr, y_expr = _build_pos_exprs(
            self.position, self.current, self.new_mon, self.offset,
            new_scale_tenths=self.new_scale_tenths,
        )
        sc = _format_scale(self.new_scale_tenths)
        cur_sc = _format_scale(_scale_tenths_from(c))
        cur_cmd = (
            f'hyprctl keyword monitor '
            f'"{c["name"]}, {c["width"]}x{c["height"]}@{c["rate"]}, '
            f'{c["x"]}x{c["y"]}, {cur_sc}"'
        )
        new_cmd = (
            f'hyprctl keyword monitor '
            f'"{n["name"]}, {n["width"]}x{n["height"]}@{n["rate"]}, '
            f'{x_expr}x{y_expr}, {sc}"'
        )
        return f"{cur_cmd}\n{new_cmd}"

    def _update_cmd(self):
        """Refresh the command textview text and color."""
        cmd_text = self._build_display_cmd()
        bx, by = calc_hypr_position(self.position, self.current, self.new_mon, self.offset)
        overlap = monitors_overlap(self.current, bx, by, self.new_mon)
        color = "#ff5a4d" if overlap else "#66e6a0"
        self.cmd_css.load_from_data(
            f"textview, textview text {{ color: {color}; font-family: monospace;"
            f"  font-size: 12px; background: transparent; }}"
            f"textview text selection {{ background-color: #3388cc; color: white; }}"
            .encode()
        )
        self.cmd_view.get_buffer().set_text(cmd_text)

    # ── Drawing ───────────────────────────────────────────────────────

    def _box_dims(self, sw):
        """Compute display-space box sizes using native resolution.

        Uses raw pixel dimensions (not divided by scale) so monitors with
        different scales appear proportional to their actual pixel count
        rather than being distorted by scale differences.
        """
        cw, ch = self.current["width"], self.current["height"]
        nw, nh = self.new_mon["width"], self.new_mon["height"]
        max_dim = max(cw, ch, nw, nh)
        s = (sw * 0.18) / max_dim
        return cw * s, ch * s, nw * s, nh * s

    def on_draw(self, widget, cr):
        alloc = widget.get_allocation()
        sw, sh = alloc.width, alloc.height

        # Background
        cr.set_source_rgba(0.05, 0.05, 0.1, 0.88)
        cr.rectangle(0, 0, sw, sh)
        cr.fill()

        cur_bw, cur_bh, new_bw, new_bh = self._box_dims(sw)

        # Tiny gap so both border colors are visible but boxes nearly touch
        gap = 4
        pos = self.position
        if pos == "right":
            total_w = cur_bw + gap + new_bw
            total_h = max(cur_bh, new_bh)
            ox = (sw - total_w) / 2
            oy = (sh - total_h) / 2
            cur_x, cur_y = ox, oy + (total_h - cur_bh) / 2
            new_x, new_y = ox + cur_bw + gap, oy + (total_h - new_bh) / 2
        elif pos == "left":
            total_w = new_bw + gap + cur_bw
            total_h = max(cur_bh, new_bh)
            ox = (sw - total_w) / 2
            oy = (sh - total_h) / 2
            new_x, new_y = ox, oy + (total_h - new_bh) / 2
            cur_x, cur_y = ox + new_bw + gap, oy + (total_h - cur_bh) / 2
        elif pos == "below":
            total_w = max(cur_bw, new_bw)
            total_h = cur_bh + gap + new_bh
            ox = (sw - total_w) / 2
            oy = (sh - total_h) / 2
            cur_x, cur_y = ox + (total_w - cur_bw) / 2, oy
            new_x, new_y = ox + (total_w - new_bw) / 2, oy + cur_bh + gap
        else:  # above
            total_w = max(cur_bw, new_bw)
            total_h = new_bh + gap + cur_bh
            ox = (sw - total_w) / 2
            oy = (sh - total_h) / 2
            new_x, new_y = ox + (total_w - new_bw) / 2, oy
            cur_x, cur_y = ox + (total_w - cur_bw) / 2, oy + new_bh + gap

        # Apply visual offset to new monitor box (perpendicular axis)
        if self.offset != 0:
            cw = self.current["width"]
            ch = self.current["height"]
            max_native = max(cw, ch)
            max_box = max(cur_bw, cur_bh)
            vis_scale = max_box / max_native if max_native else 1
            visual_off = self.offset * self.current["scale"] * vis_scale
            if pos in ("right", "left"):
                new_y += visual_off
            else:
                new_x += visual_off

        # Draw monitor boxes
        self._draw_monitor_box(
            cr, cur_x, cur_y, cur_bw, cur_bh,
            self.current, border_color=(0.4, 0.8, 0.4), is_current=True,
        )
        self._draw_monitor_box(
            cr, new_x, new_y, new_bw, new_bh,
            self.new_mon, border_color=(0.2, 0.8, 1.0), is_current=False,
        )

        # Snap alignment guide lines
        self._draw_snap_lines(cr, cur_x, cur_y, cur_bw, cur_bh,
                              new_x, new_y, new_bw, new_bh)

        # --- Bottom info area (drawn upward from bottom) ---
        # Command row is a GTK widget (see __init__), not drawn here.
        cr.select_font_face("Sans", 0, 0)
        bottom_y = sh - 30

        # Row 1 (lowest): hint bar
        hint = "Arrows: position  \u00b7  Alt+Arrow: fine-tune \u00b125  \u00b7  Shift+Arrow: \u00b11  \u00b7  s/S: scale \u00b10.1  \u00b7  Ctrl+C: copy  \u00b7  Enter: confirm  \u00b7  Esc: cancel"
        cr.set_source_rgba(1, 1, 1, 0.45)
        cr.set_font_size(14)
        te = cr.text_extents(hint)
        cr.move_to((sw - te.width) / 2, bottom_y)
        cr.show_text(hint)

        # Row 2: command is the GTK textview (skip — 2 lines + label + padding)
        bottom_y = sh - 120

        # Row 3: scale (only when changed from original)
        if self.new_scale_tenths != self.orig_scale_tenths:
            scale_label = f"Scale: {_format_scale(self.orig_scale_tenths)} \u2192 {_format_scale(self.new_scale_tenths)}"
            cr.select_font_face("Sans", 0, 0)
            cr.set_source_rgba(1.0, 0.8, 0.2, 0.8)
            cr.set_font_size(16)
            te = cr.text_extents(scale_label)
            cr.move_to((sw - te.width) / 2, bottom_y)
            cr.show_text(scale_label)
            bottom_y -= 28

        # Row 4: offset (only when non-zero)
        if self.offset != 0:
            axis = "vertical" if pos in ("right", "left") else "horizontal"
            offset_label = f"Offset: {self.offset:+d}px {axis}"
            cr.select_font_face("Sans", 0, 0)
            cr.set_source_rgba(0.2, 0.8, 1.0, 0.7)
            cr.set_font_size(16)
            te = cr.text_extents(offset_label)
            cr.move_to((sw - te.width) / 2, bottom_y)
            cr.show_text(offset_label)
            bottom_y -= 28

        # Row 5 (topmost): position label
        pos_label = f"Position: {pos.capitalize()}"
        cr.select_font_face("Sans", 0, 0)
        cr.set_source_rgba(1, 1, 1, 0.7)
        cr.set_font_size(20)
        te = cr.text_extents(pos_label)
        cr.move_to((sw - te.width) / 2, bottom_y)
        cr.show_text(pos_label)

    def _draw_monitor_box(self, cr, x, y, w, h, mon, border_color, is_current):
        # Fill
        cr.set_source_rgba(0.15, 0.15, 0.2, 0.9)
        cr.rectangle(x, y, w, h)
        cr.fill()

        # Border
        cr.set_source_rgba(*border_color, 1.0)
        cr.set_line_width(3 if is_current else 2.5)
        cr.rectangle(x, y, w, h)
        cr.stroke()

        # Tag label (inside box, top)
        tag = "Current" if is_current else "New"
        cr.set_source_rgba(*border_color, 0.8)
        cr.select_font_face("Sans", 0, 0)
        cr.set_font_size(11)
        te = cr.text_extents(tag)
        cr.move_to(x + (w - te.width) / 2, y + 16)
        cr.show_text(tag)

        # Icon
        icon = mon.get("icon", "")
        cr.set_source_rgba(1, 1, 1, 0.9)
        cr.set_font_size(min(w, h) * 0.22)
        te = cr.text_extents(icon)
        cr.move_to(x + (w - te.width) / 2, y + h * 0.38)
        cr.show_text(icon)

        # Resolution label
        res = f"{mon['width']}x{mon['height']}@{mon['rate']}Hz"
        cr.set_source_rgba(1, 1, 1, 0.85)
        cr.set_font_size(min(w * 0.08, 13))
        te = cr.text_extents(res)
        cr.move_to(x + (w - te.width) / 2, y + h * 0.55)
        cr.show_text(res)

        # Device name
        cr.set_source_rgba(1, 1, 1, 0.6)
        cr.set_font_size(min(w * 0.07, 12))
        te = cr.text_extents(mon["name"])
        cr.move_to(x + (w - te.width) / 2, y + h * 0.68)
        cr.show_text(mon["name"])

        # Scale info (use _format_scale for clean display of edited values)
        scale_text = f"scale {_format_scale(round(mon['scale'] * 10))}"
        lw, lh = logical_size(mon)
        logical_text = f"{int(lw)}x{int(lh)} logical"
        cr.set_source_rgba(1, 1, 1, 0.4)
        cr.set_font_size(min(w * 0.06, 10))
        te = cr.text_extents(scale_text)
        cr.move_to(x + (w - te.width) / 2, y + h * 0.80)
        cr.show_text(scale_text)
        te = cr.text_extents(logical_text)
        cr.move_to(x + (w - te.width) / 2, y + h * 0.90)
        cr.show_text(logical_text)


def main():
    if len(sys.argv) < 2:
        print("Usage: monitor-picker.py <monitor-to-place>", file=sys.stderr)
        sys.exit(1)

    target_name = sys.argv[1]

    current = get_active_monitor(target_name)
    if not current:
        print("No active monitor found", file=sys.stderr)
        sys.exit(1)

    new_mon = get_monitor_by_name(target_name)
    if not new_mon:
        print(f"Unknown monitor: {target_name}", file=sys.stderr)
        sys.exit(1)

    picker = MonitorPicker(current, new_mon)
    Gtk.main()

    if picker.result:
        cur_cfg, new_cfg = picker.result
        print(cur_cfg)
        print(new_cfg)
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
