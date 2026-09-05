#!/usr/bin/env python3
"""Background layout editor using GTK3 + Cairo.

Sibling of monitor-picker.py: shows all monitors at their true coordinates,
each previewing its CURRENT wallpaper. Edits how images are placed — per
monitor or spanned across any subset — with full pan/zoom/fit control. The
engine (bg-layout.py + bglayout/) renders real slices; this GUI previews with
the exact same math (bglayout.geometry), so preview == render.

  Select    : click a monitor, Tab cycles groups, Ctrl+Click / 1-9/0 toggle,
              a = all/none, click empty space = clear selection
  Group     : g = span the selected monitors, u = ungroup the active group
  Place     : drag inside the active group pans; scroll (Shift: fine) zooms
              about the cursor; Arrows pan ±25 px (Shift ±1, Alt ±200);
              +/- zoom; z reset; f/F cycle fill/fit/center/tile/stretch
  Image     : click a thumbnail or [ / ] to pick which image you're editing;
              o adds images from disk to the strip (never copied into the
              theme, and forgotten when /tmp is cleared)
  Presets   : p = preset menu (apply/delete), Ctrl+S = save current as preset
  Live      : L = live-apply previews to the real wallpapers while editing
  Confirm   : Enter saves layouts + prints apply commands (caller runs them);
              Esc or closing the window cancels (restoring wallpapers if
              live-apply touched them)
  Extras    : e = edit raw commands, Ctrl+C = copy commands

Nothing touches the original images; rendered slices live in /tmp. Layouts
persist under ~/.config/omarchy/background-layouts/ only on Enter.

An ordinary toplevel, not a layer-shell overlay: it opens at the size of the
monitor it lands on, and the window rule on its app id (see hyprland.conf)
floats it, so it can be moved, resized and closed like any other window. The
file chooser is a modal child of it and therefore always sits on top.
"""

import copy
import json
import os
import re
import subprocess
import sys

import cairo

import gi
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPTS_DIR)

import bg_picker_state as st  # noqa: E402
from bglayout import store  # noqa: E402
from bglayout.geometry import (member_crop, mons_from_hyprctl,  # noqa: E402
                               region_phys)

APP_ID = "omarchy.background-picker"
WS_MAP_FILE = "/tmp/hypr-workspace-bg-map"
EXTRA_FILE = "/tmp/hypr-bg-extra-images"
ARRANGE_FILE = "/tmp/hypr-bg-arrangement"
LOCK_MARK = "/tmp/hypr-bg-locked"
INDEX_FILE = "/tmp/hypr-bg-layout/index.tsv"
PREVIEW_DIR = "/tmp/hypr-bg-layout/preview"
ENGINE = os.path.join(SCRIPTS_DIR, "bg-layout.py")
WS_BG_SCRIPT = os.path.join(SCRIPTS_DIR, "workspace-backgrounds.sh")

ARROW_DIRS = {"Left": "left", "Right": "right", "Up": "up", "Down": "down"}
NUDGE_COARSE = 25     # Arrow pan step (logical px)
NUDGE_FINE = 1        # Shift+Arrow
NUDGE_HUGE = 200      # Alt+Arrow
ZOOM_STEP = 1.1       # +/- keys
SCROLL_ZOOM = 1.05    # wheel
SCROLL_ZOOM_FINE = 1.01
SNAP_PHYS = 24        # pan snap threshold in region-phys px
BOX_GAP = 2
DRAG_THRESHOLD = 4    # screen px before a press becomes a pan
PIXBUF_MAX_W = 2048   # preview decode cap
THUMB_H = 72
LIVE_APPLY_MS = 150

_CLEAN_MASK = ~(
    Gdk.ModifierType.MOD2_MASK      # NumLock
    | Gdk.ModifierType.LOCK_MASK    # CapsLock
    | Gdk.ModifierType.MOD3_MASK    # ScrollLock
)


# ── external queries ──────────────────────────────────────────────────

def _query_hypr_monitors():
    try:
        result = subprocess.run(
            ["hyprctl", "monitors", "-j"],
            capture_output=True, text=True, check=True,
        )
        return json.loads(result.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return []


def _query_awww():
    try:
        result = subprocess.run(
            ["awww", "query"], capture_output=True, text=True, check=True,
        )
        return st.parse_awww_query(result.stdout)
    except (OSError, subprocess.CalledProcessError):
        return {}


def _read_ws_map():
    try:
        with open(WS_MAP_FILE) as f:
            return [line.strip() for line in f]
    except OSError:
        return []


def _slice_to_image():
    """{slice_path: image_path} from the engine index, to reverse-map awww
    query results that point at rendered slices."""
    out = {}
    try:
        with open(INDEX_FILE) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 5:
                    out[parts[2]] = parts[0]
                    out[parts[3]] = parts[0]
    except OSError:
        pass
    return out


def get_backgrounds():
    """Sorted background paths — same discovery as workspace-backgrounds.sh."""
    theme_name = ""
    try:
        with open(os.path.expanduser("~/.config/omarchy/current/theme.name")) as f:
            theme_name = f.read().strip()
    except OSError:
        pass
    dirs = [
        os.path.expanduser(f"~/.config/omarchy/backgrounds/{theme_name}"),
        os.path.expanduser("~/.config/omarchy/current/theme/backgrounds"),
    ]
    paths = []
    for d in dirs:
        try:
            paths.extend(os.path.join(d, n) for n in os.listdir(d)
                         if os.path.isfile(os.path.join(d, n)))
        except OSError:
            pass
    return sorted(paths)


def read_extras():
    """Images added by hand in an earlier run of the editor. Anything that has
    since gone away or stopped being an image is dropped silently."""
    try:
        with open(EXTRA_FILE) as f:
            paths = [line.strip() for line in f if line.strip()]
    except OSError:
        return []
    return [p for p in paths if os.path.isfile(p) and st.is_image_file(p)]


def write_extras(paths):
    tmp = EXTRA_FILE + ".tmp"
    try:
        with open(tmp, "w") as f:
            for p in paths:
                f.write(p + "\n")
        os.replace(tmp, EXTRA_FILE)
    except OSError:
        pass


def current_images(mons, ws_active):
    """{monitor: true image path}. Primary source: the per-workspace map;
    fallback: awww query, reverse-mapped through the slice index."""
    ws_map = _read_ws_map()
    images = {}
    for m in mons:
        ws = ws_active.get(m.name)
        if ws and 1 <= ws <= len(ws_map) and ws_map[ws - 1]:
            images[m.name] = ws_map[ws - 1]
    missing = [m.name for m in mons if m.name not in images]
    if missing:
        rev = _slice_to_image()
        for name, path in _query_awww().items():
            if name in missing:
                images[name] = rev.get(path, path)
    return images


# ── GTK editor ────────────────────────────────────────────────────────

class BackgroundEditor(Gtk.Window):
    def __init__(self, mons, backgrounds, preselect=None, extras=()):
        super().__init__(title="Background Layout")
        self.set_app_paintable(True)
        self.set_name(APP_ID)

        self.mons = mons                       # list[geometry.Mon], enabled only
        self.mons_by_name = {m.name: m for m in mons}
        self.extras = list(extras)             # images added from outside the theme
        self.backgrounds = list(backgrounds) + self.extras
        self.focused_name = None
        self.mon_reserved = {}                 # monitor -> [l, t, r, b] logical
        self.ws_active = {}
        self.mon_image = {}
        self.selected = set()                  # grouping selection
        self.active_members = None             # frozenset of the active group
        self.edit_image = None
        self.image_pinned = False
        self.layouts = {}                      # image -> groups (picker model)
        self.letterbox = {}                    # image -> "#rrggbb"
        self.load_errors = {}                  # image -> sidecar error string
        self.dirty = set()
        self.result = None
        self.edit_mode = False
        self.cmd_edited = False
        self.live_apply = False
        self._live_applied_any = False
        self._live_state = {}                  # monitor -> image actually painted
        self.lock_warning = None               # extras that force the lock, or None
        self._locked_already = os.path.isfile(LOCK_MARK)
        self._chooser_dir = None
        self._live_timer = None
        self._xform = None                     # (s, ox, oy, min_x, min_y)
        self._press = None                     # (x, y, mon_name) pre-drag
        self._drag = None                      # (x, y, region_snapshot, members)
        self._snapped_axes = set()
        self._pix = {}                         # image -> GdkPixbuf (capped)
        self._img_size = {}                    # image -> (w, h) true size
        self._thumbs = {}
        self._thumb_hits = []                  # [(x, y, w, h, path)] per draw
        self.preset_menu = None                # {"names": [...], "sel": int}
        self.flash_msg = ""

        self._poll_state(initial=True)
        if preselect and preselect in self.mons_by_name:
            self.selected = {preselect}
            self._activate_monitor(preselect)

        # Fill the monitor it opens on, but as a plain window: a layer-shell
        # overlay is outside the compositor's window management, so it could
        # not be moved, resized or closed by any of the usual means. The
        # reserved strip comes off the height, because waybar is a layer above
        # ordinary windows and would otherwise sit on the thumbnail row.
        here = self.mons_by_name.get(self.focused_name) or self.mons[0]
        res = self.mon_reserved.get(here.name) or [0, 0, 0, 0]
        self.set_default_size(int(here.lw - res[0] - res[2]),
                              int(here.lh - res[1] - res[3]))

        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)

        # Widget tree: Overlay -> DrawingArea + bottom command TextView
        overlay = Gtk.Overlay()
        self.add(overlay)

        self.darea = Gtk.DrawingArea()
        self.darea.set_can_focus(True)
        self.darea.connect("draw", self.on_draw)
        self.darea.add_events(
            Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.POINTER_MOTION_MASK
            | Gdk.EventMask.SCROLL_MASK
            | Gdk.EventMask.SMOOTH_SCROLL_MASK
        )
        self.darea.connect("button-press-event", self.on_button_press)
        self.darea.connect("button-release-event", self.on_button_release)
        self.darea.connect("motion-notify-event", self.on_motion)
        self.darea.connect("scroll-event", self.on_scroll)
        overlay.add(self.darea)

        cmd_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        cmd_box.set_valign(Gtk.Align.END)
        cmd_box.set_halign(Gtk.Align.CENTER)
        cmd_box.set_margin_bottom(46)

        self.cmd_prefix_label = Gtk.Label(label="Apply commands (to be run) — e: edit:")
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

        # Preset-name entry (hidden until Ctrl+S)
        self.name_entry = Gtk.Entry()
        self.name_entry.set_placeholder_text("preset name — Enter: save, Esc: cancel")
        self.name_entry.set_valign(Gtk.Align.CENTER)
        self.name_entry.set_halign(Gtk.Align.CENTER)
        self.name_entry.set_width_chars(36)
        self.name_entry.set_no_show_all(True)
        self.name_entry.connect("activate", self._on_name_entry_activate)
        self.name_entry.connect("key-press-event", self._on_name_entry_key)
        overlay.add_overlay(self.name_entry)

        self.add_events(Gdk.EventMask.KEY_PRESS_MASK)
        self.set_can_focus(True)
        self.connect("key-press-event", self.on_key)
        self.darea.connect("key-press-event", self.on_key)
        self.connect("delete-event", self._on_delete)
        self.connect("destroy", Gtk.main_quit)

        self._poll_id = GLib.timeout_add(1000, self._on_poll)

        self.show_all()
        self.darea.grab_focus()
        if self.edit_image is None:
            self._default_edit_image()
        self._update_cmd()

    def _on_delete(self, *_):
        """Closing the window is a cancel, not a silent exit: live-apply may
        have painted real wallpapers that have to be put back."""
        self._cancel()
        return False

    # ── live state polling ────────────────────────────────────────────

    def _poll_state(self, initial=False):
        monitors = _query_hypr_monitors()
        if monitors and not initial:
            live = [m for m in mons_from_hyprctl(monitors) if not m.disabled]
            if [m.name for m in live] != [m.name for m in self.mons]:
                self._monitors_changed(live)
        if monitors:
            active = {}
            for hm in monitors:
                if hm.get("focused"):
                    self.focused_name = hm.get("name")
                active[hm.get("name")] = (hm.get("activeWorkspace") or {}).get("id")
                self.mon_reserved[hm.get("name")] = hm.get("reserved") or [0, 0, 0, 0]
            self.ws_active = active
        images = current_images(self.mons, self.ws_active)
        if images or initial:
            self.mon_image = images

    def _monitors_changed(self, live):
        """A display arrived or left while the editor was open. Everything
        keyed on monitor names has to follow, or the next draw paints boxes for
        a screen that is not there and live-apply talks to a dead output.

        Layouts are reshaped in memory only; nothing is marked dirty, so an
        image the user never touched keeps its sidecar exactly as it is."""
        names = [m.name for m in live]
        self.mons = live
        self.mons_by_name = {m.name: m for m in live}
        for image in list(self.layouts):
            self.layouts[image] = st.regroup(self.layouts[image], names)
        keep = set(names)
        self.selected &= keep
        self._live_state = {k: v for k, v in self._live_state.items() if k in keep}
        self.mon_image = {k: v for k, v in self.mon_image.items() if k in keep}
        if self.active_members:
            self.active_members = frozenset(set(self.active_members) & keep) or None
        if not self.active_members:
            self._activate_monitor(self.focused_name if self.focused_name in keep
                                   else (names[0] if names else None))
        self.flash_msg = "displays changed: " + (", ".join(names) or "none left")
        self._update_cmd()
        self.darea.queue_draw()

    def _on_poll(self):
        before = (self.focused_name, dict(self.ws_active), dict(self.mon_image))
        self._poll_state()
        if before != (self.focused_name, self.ws_active, self.mon_image):
            self.darea.queue_draw()
        return True

    # ── model helpers ─────────────────────────────────────────────────

    def _default_edit_image(self):
        name = self.focused_name or (self.mons[0].name if self.mons else None)
        img = self.mon_image.get(name) or (self.backgrounds[0]
                                           if self.backgrounds else None)
        if img:
            self._set_edit_image(img, pin=False)

    def _groups_for(self, image):
        """Lazy-load an image's layout into the picker group model."""
        if image not in self.layouts:
            layout = None
            try:
                layout = store.load_layout(image)
            except store.LayoutError as e:
                self.load_errors[image] = str(e)
            self.layouts[image] = st.layout_groups_for(
                layout, [m.name for m in self.mons])
            if layout and layout.get("letterbox"):
                self.letterbox[image] = layout["letterbox"]
        return self.layouts[image]

    def _groups(self):
        return self._groups_for(self.edit_image) if self.edit_image else []

    def _set_edit_image(self, image, pin):
        self.edit_image = image
        if pin:
            self.image_pinned = True
        self._groups_for(image)
        if self.active_members is None or not any(
                set(g["monitors"]) == set(self.active_members)
                for g in self._groups()):
            name = self.focused_name or (self.mons[0].name if self.mons else None)
            self._activate_monitor(name)

    def _activate_monitor(self, name):
        g = st.group_of(self._groups(), name) if name else None
        self.active_members = frozenset(g["monitors"]) if g else None

    def _active_group(self):
        if not self.active_members:
            return None
        for g in self._groups():
            if set(g["monitors"]) == set(self.active_members):
                return g
        return None

    def _cycle_group(self, step=1):
        groups = self._groups()
        if not groups:
            return
        keys = [frozenset(g["monitors"]) for g in groups]
        try:
            idx = keys.index(frozenset(self.active_members or ()))
        except ValueError:
            idx = -step
        self.active_members = keys[(idx + step) % len(keys)]

    def _group_geom(self, g):
        """(lx, ly, dref, rw, rh) for a group's live members."""
        members = [self.mons_by_name[n] for n in g["monitors"]
                   if n in self.mons_by_name]
        return region_phys(members)

    def _img_dims(self, image):
        if image not in self._img_size:
            pix = self._pixbuf(image)
            if pix is None:
                return None
        return self._img_size.get(image)

    def _pixbuf(self, image):
        if image not in self._pix:
            try:
                fmt = GdkPixbuf.Pixbuf.get_file_info(image)
                if not fmt or not fmt[1] or not fmt[2]:
                    raise GLib.Error.new_literal(
                        GLib.quark_from_string("bg"), "unreadable", 0)
                w, h = fmt[1], fmt[2]
                self._img_size[image] = (w, h)
                if w > PIXBUF_MAX_W:
                    pix = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                        image, PIXBUF_MAX_W, -1, True)
                else:
                    pix = GdkPixbuf.Pixbuf.new_from_file(image)
                self._pix[image] = pix
            except GLib.Error:
                self._pix[image] = None
        return self._pix[image]

    def _thumb(self, image):
        if image not in self._thumbs:
            try:
                self._thumbs[image] = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                    image, -1, THUMB_H, True)
            except GLib.Error:
                self._thumbs[image] = None
        return self._thumbs[image]

    def _mark_dirty(self):
        if self.edit_image:
            self.dirty.add(self.edit_image)
        self._layout_changed()

    def _layout_changed(self):
        # Any edit makes a pending warning stale: it names the images that
        # were about to be locked in, and that set can change under it.
        self.lock_warning = None
        self.darea.queue_draw()
        self._update_cmd()
        if self.live_apply:
            self._schedule_live_apply()

    def _mixed_span_warning(self):
        g = self._active_group()
        if not g or len(g["monitors"]) < 2 or not self.edit_image:
            return None
        others = [n for n in sorted(g["monitors"])
                  if self.mon_image.get(n) not in (None, self.edit_image)]
        if not others:
            return None
        names = ", ".join(others)
        return (f"{names} currently show a different image — applying paints "
                f"them with {os.path.basename(self.edit_image)}")

    # ── images from outside the theme ─────────────────────────────────

    def _probe_image(self, path):
        """(w, h) if GdkPixbuf can actually decode it, else None. The header
        sniff in bg_picker_state says what a file claims to be; this says
        whether this machine has a loader for it."""
        try:
            fmt = GdkPixbuf.Pixbuf.get_file_info(path)
        except GLib.Error:
            return None
        if not fmt or not fmt[0] or not fmt[1] or not fmt[2]:
            return None
        return fmt[1], fmt[2]

    def _open_image_chooser(self):
        """Add images to the strip. Modal and transient for the editor, so it
        stays on top of it and hands focus back on close."""
        dlg = Gtk.FileChooserDialog(title="Add background images",
                                    transient_for=self, modal=True,
                                    action=Gtk.FileChooserAction.OPEN)
        dlg.add_buttons("Cancel", Gtk.ResponseType.CANCEL,
                        "Add", Gtk.ResponseType.ACCEPT)
        dlg.set_select_multiple(True)
        dlg.set_default_size(1000, 680)
        dlg.set_keep_above(True)
        dlg.set_current_folder(self._chooser_dir or os.path.expanduser("~"))
        filt = Gtk.FileFilter()
        filt.set_name("Images")
        for fmt in GdkPixbuf.Pixbuf.get_formats():
            for mime in fmt.get_mime_types():
                filt.add_mime_type(mime)
        dlg.set_filter(filt)
        preview = Gtk.Image()
        dlg.set_preview_widget(preview)
        dlg.connect("update-preview", self._on_chooser_preview, preview)
        paths = dlg.get_filenames() if dlg.run() == Gtk.ResponseType.ACCEPT else []
        self._chooser_dir = dlg.get_current_folder()
        dlg.destroy()
        self.present()
        self.darea.grab_focus()
        self._add_extras(paths)
        return True

    def _on_chooser_preview(self, dlg, widget):
        path = dlg.get_preview_filename()
        pix = None
        if path and os.path.isfile(path):
            try:
                pix = GdkPixbuf.Pixbuf.new_from_file_at_scale(path, 240, 240, True)
            except GLib.Error:
                pix = None
        widget.set_from_pixbuf(pix)
        dlg.set_preview_widget_active(pix is not None)

    def _add_extras(self, paths):
        if not paths:
            return
        kept, rejected = st.merge_extras(self.extras, paths, self.backgrounds)
        # Header sniffing got them this far; drop anything GdkPixbuf still
        # cannot open, so a thumbnail never comes up blank.
        usable = []
        for path in kept[len(self.extras):]:
            if self._probe_image(path):
                usable.append(path)
            else:
                rejected.append(path)
        if usable:
            self.extras += usable
            self.backgrounds += usable
            write_extras(self.extras)
            self._set_edit_image(usable[0], pin=True)
        bits = []
        if usable:
            bits.append(f"added {len(usable)} image(s)")
        if rejected:
            bits.append("not a usable image: " + ", ".join(
                sorted({os.path.basename(p) for p in rejected})))
        self.flash_msg = "  ·  ".join(bits) or "already in the strip"
        self._layout_changed()

    def _extras_in_use(self):
        # The arrangement, not just what live-apply painted this run: reopening
        # the editor on an already-locked desktop finds the added images in
        # mon_image instead, and confirming there must still lock.
        return st.extras_in_use(self._arrangement(), self.extras)

    def _arrangement(self):
        return st.arrangement([m.name for m in self.mons], self.mon_image,
                              self._live_state)

    def _write_arrangement(self):
        tmp = ARRANGE_FILE + ".tmp"
        try:
            with open(tmp, "w") as f:
                for mon, img in sorted(self._arrangement().items()):
                    f.write(f"{mon}\t{img}\n")
            os.replace(tmp, ARRANGE_FILE)
        except OSError as e:
            print(f"failed to write arrangement: {e}", file=sys.stderr)

    # ── key handling ──────────────────────────────────────────────────

    def _on_textview_key(self, widget, event):
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

    def _on_name_entry_key(self, widget, event):
        if Gdk.keyval_name(event.keyval) == "Escape":
            self.name_entry.hide()
            self.darea.grab_focus()
            return True
        return False

    def _on_name_entry_activate(self, widget):
        name = self.name_entry.get_text().strip()
        self.name_entry.hide()
        self.darea.grab_focus()
        if not name or not self.edit_image:
            return
        layout = st.serialize_layout(self.edit_image, self._groups(),
                                     self.letterbox.get(self.edit_image))
        if layout is None:
            self.flash_msg = "nothing to save — layout is all defaults"
            self.darea.queue_draw()
            return
        try:
            store.save_preset(name, layout)
            self.flash_msg = f"preset '{name}' saved"
        except store.LayoutError as e:
            self.flash_msg = f"preset not saved: {e}"
        self.darea.queue_draw()

    def on_key(self, widget, event):
        key = Gdk.keyval_name(event.keyval)
        ctrl = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.CONTROL_MASK)
        shift = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.SHIFT_MASK)
        alt = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.MOD1_MASK)
        self.flash_msg = ""

        if self.preset_menu is not None:
            return self._preset_menu_key(key)

        if key == "Escape":
            if self.lock_warning is not None:
                self.lock_warning = None
                self.darea.queue_draw()
                return True
            if self.edit_mode:
                self._exit_edit_mode()
                return True
            self._cancel()
            return True

        if self.edit_mode and widget is not self.cmd_view:
            if not (ctrl and key in ("Return", "KP_Enter")):
                return False

        if key in ("Return", "KP_Enter"):
            return self._confirm()

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

        if ctrl and key in ("s", "S"):
            self.name_entry.show()
            self.name_entry.set_text("")
            self.name_entry.grab_focus()
            return True

        # Arrows — pan the active group's image
        if key in ARROW_DIRS:
            g = self._active_group()
            if not g or not self.edit_image:
                return True
            dims = self._img_dims(self.edit_image)
            if not dims:
                return True
            step = NUDGE_FINE if shift else NUDGE_HUGE if alt else NUDGE_COARSE
            _, _, dref, rw, rh = self._group_geom(g)
            dpx = {"left": -step, "right": step}.get(ARROW_DIRS[key], 0) * dref
            dpy = {"up": -step, "down": step}.get(ARROW_DIRS[key], 0) * dref
            g["region"] = st.pan_by(g["region"], dpx, dpy, dims, rw, rh)
            self._mark_dirty()
            return True

        if key in ("plus", "equal", "KP_Add", "minus", "KP_Subtract"):
            factor = ZOOM_STEP if key in ("plus", "equal", "KP_Add") else 1 / ZOOM_STEP
            self._zoom_active(factor, anchor=None)
            return True

        if key == "z":
            g = self._active_group()
            if g:
                g["region"]["zoom"] = 1.0
                g["region"]["pan"] = [0.0, 0.0]
                self._mark_dirty()
            return True

        if key in ("f", "F"):
            g = self._active_group()
            if g:
                g["region"] = st.cycle_mode(g["region"], 1 if key == "f" else -1)
                self._mark_dirty()
            return True

        if key == "g":
            if len(self.selected) >= 2 and self.edit_image:
                self.layouts[self.edit_image] = st.make_group(
                    self._groups(), self.selected)
                self.active_members = frozenset(self.selected)
                self._mark_dirty()
            else:
                self.flash_msg = "select 2+ monitors (Ctrl+Click / digits) then g"
                self.darea.queue_draw()
            return True

        if key == "u":
            g = self._active_group()
            if g and len(g["monitors"]) > 1 and self.edit_image:
                self.layouts[self.edit_image] = st.split_group(self._groups(), g)
                self.active_members = frozenset(list(g["monitors"])[:1])
                self._mark_dirty()
            return True

        if key in ("Tab", "ISO_Left_Tab"):
            self._cycle_group(-1 if key == "ISO_Left_Tab" else 1)
            self.darea.queue_draw()
            return True

        if key.isdigit():
            idx = 9 if key == "0" else int(key) - 1
            if idx < len(self.mons):
                name = self.mons[idx].name
                self.selected.symmetric_difference_update({name})
                if name in self.selected:
                    self._on_monitor_activated(name)
                self.darea.queue_draw()
            return True

        if key == "a":
            if len(self.selected) == len(self.mons):
                self.selected = set()
            else:
                self.selected = {m.name for m in self.mons}
            self.darea.queue_draw()
            return True

        if key == "bracketleft" or key == "bracketright":
            if self.backgrounds:
                cur = (self.backgrounds.index(self.edit_image)
                       if self.edit_image in self.backgrounds else 0)
                step = 1 if key == "bracketright" else -1
                self._set_edit_image(
                    self.backgrounds[(cur + step) % len(self.backgrounds)],
                    pin=True)
                self._layout_changed()
            return True

        if key == "o":
            return self._open_image_chooser()

        if key == "p":
            self._open_preset_menu()
            return True

        if key == "L":
            self.live_apply = not self.live_apply
            if self.live_apply:
                self._schedule_live_apply()
            self.darea.queue_draw()
            return True

        if key == "e":
            self._enter_edit_mode()
            return True

        return False

    def _zoom_active(self, factor, anchor=None):
        """Zoom the active group about `anchor` (region-phys) or its center."""
        g = self._active_group()
        if not g or not self.edit_image:
            return
        dims = self._img_dims(self.edit_image)
        if not dims:
            return
        _, _, _, rw, rh = self._group_geom(g)
        if anchor is None:
            anchor = (rw / 2, rh / 2)
        g["region"] = st.zoom_about(g["region"], factor, anchor, dims, rw, rh)
        self._mark_dirty()

    # ── preset menu ───────────────────────────────────────────────────

    def _open_preset_menu(self):
        try:
            names = sorted(store.load_presets()["presets"])
        except store.LayoutError as e:
            self.flash_msg = f"presets unreadable: {e}"
            self.darea.queue_draw()
            return
        if not names:
            self.flash_msg = "no presets saved yet — Ctrl+S saves the current layout"
            self.darea.queue_draw()
            return
        self.preset_menu = {"names": names, "sel": 0}
        self.darea.queue_draw()

    def _preset_menu_key(self, key):
        menu = self.preset_menu
        if key == "Escape" or key == "p":
            self.preset_menu = None
            self.darea.queue_draw()
            return True
        if key in ("Down", "j"):
            menu["sel"] = (menu["sel"] + 1) % len(menu["names"])
            self.darea.queue_draw()
            return True
        if key in ("Up", "k"):
            menu["sel"] = (menu["sel"] - 1) % len(menu["names"])
            self.darea.queue_draw()
            return True
        if key.isdigit() and key != "0":
            idx = int(key) - 1
            if idx < len(menu["names"]):
                menu["sel"] = idx
                self._apply_preset(menu["names"][idx])
            return True
        if key in ("Return", "KP_Enter"):
            self._apply_preset(menu["names"][menu["sel"]])
            return True
        if key == "d":
            name = menu["names"].pop(menu["sel"])
            try:
                data = store.load_presets()
                data["presets"].pop(name, None)
                store.save_presets(data)
                self.flash_msg = f"preset '{name}' deleted"
            except store.LayoutError as e:
                self.flash_msg = f"delete failed: {e}"
            if not menu["names"]:
                self.preset_menu = None
            else:
                menu["sel"] = min(menu["sel"], len(menu["names"]) - 1)
            self.darea.queue_draw()
            return True
        return True  # swallow everything else while the menu is open

    def _apply_preset(self, name):
        """Copy a preset's regions into the edit image's in-memory groups —
        persisted only on Enter, like every other edit."""
        if not self.edit_image:
            return
        try:
            data = store.load_presets()
            preset = data["presets"][name]
        except (store.LayoutError, KeyError) as e:
            self.flash_msg = f"preset unusable: {e}"
            self.preset_menu = None
            self.darea.queue_draw()
            return
        self.layouts[self.edit_image] = st.layout_groups_for(
            {"regions": copy.deepcopy(preset["regions"])},
            [m.name for m in self.mons])
        if preset.get("letterbox"):
            self.letterbox[self.edit_image] = preset["letterbox"]
        self._activate_monitor(self.focused_name)
        self.preset_menu = None
        self.flash_msg = f"preset '{name}' applied to {os.path.basename(self.edit_image)}"
        self._mark_dirty()

    # ── confirm / cancel ──────────────────────────────────────────────

    def _apply_cmds(self):
        # An added image on screen means the repaint has to become a freeze:
        # see st.apply_commands.
        return st.apply_commands(self.dirty, ENGINE, WS_BG_SCRIPT,
                                 bool(self._extras_in_use()))

    def _confirm(self):
        # Nothing about the layout editor implies switching a feature off, so
        # say it out loud and make the user press Enter a second time.
        if (self._extras_in_use() and self.lock_warning is None
                and not self._locked_already):
            self.lock_warning = self._extras_in_use()
            self.darea.queue_draw()
            return True
        if self._extras_in_use():
            self._write_arrangement()
        if self.cmd_edited:
            cmds = self._parse_edited_cmd()
            if not cmds:
                return True
            self._persist_dirty()
            self.result = tuple(cmds)
            Gtk.main_quit()
            return True
        self._persist_dirty()
        self.result = tuple(self._apply_cmds())
        Gtk.main_quit()
        return True

    def _persist_dirty(self):
        for image in sorted(self.dirty):
            groups = self.layouts.get(image)
            if groups is None:
                continue
            layout = st.serialize_layout(image, groups,
                                         self.letterbox.get(image))
            try:
                if layout is None:
                    store.delete_layout(image)
                else:
                    store.save_layout(image, layout)
            except store.LayoutError as e:
                print(f"failed to save layout for {image}: {e}",
                      file=sys.stderr)

    def _cancel(self):
        self.result = None
        if self._live_applied_any:
            subprocess.run([WS_BG_SCRIPT, "apply-all"], check=False,
                           timeout=30)
        Gtk.main_quit()

    # ── mouse handling ────────────────────────────────────────────────

    def _mon_at(self, px, py):
        if not self._xform:
            return None
        s, ox, oy, min_x, min_y = self._xform
        lx = (px - ox) / s + min_x
        ly = (py - oy) / s + min_y
        for m in self.mons:
            if m.lx <= lx < m.lx + m.lw and m.ly <= ly < m.ly + m.lh:
                return m
        return None

    def _thumb_at(self, px, py):
        for x, y, w, h, path in self._thumb_hits:
            if x <= px < x + w and y <= py < y + h:
                return path
        return None

    def _on_monitor_activated(self, name):
        """Clicking/selecting a monitor makes its group active; unpinned edit
        image follows reality."""
        if not self.image_pinned:
            img = self.mon_image.get(name)
            if img and img != self.edit_image:
                self._set_edit_image(img, pin=False)
        self._activate_monitor(name)

    def on_button_press(self, widget, event):
        if event.button != 1 or self.edit_mode:
            return False
        self.darea.grab_focus()
        if self.preset_menu is not None:
            self.preset_menu = None
            self.darea.queue_draw()
            return True
        thumb = self._thumb_at(event.x, event.y)
        if thumb:
            self._set_edit_image(thumb, pin=True)
            self._layout_changed()
            return True
        mon = self._mon_at(event.x, event.y)
        ctrl = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.CONTROL_MASK)
        if mon is None:
            self.selected = set()
            self.darea.queue_draw()
            return True
        if ctrl:
            self.selected.symmetric_difference_update({mon.name})
            if mon.name in self.selected:
                self._on_monitor_activated(mon.name)
            self.darea.queue_draw()
            return True
        if mon.name not in self.selected:
            self.selected = {mon.name}
        self._on_monitor_activated(mon.name)
        g = self._active_group()
        if g and mon.name in g["monitors"]:
            self._press = (event.x, event.y,
                           copy.deepcopy(g["region"]),
                           frozenset(g["monitors"]))
        self.darea.queue_draw()
        return True

    def on_motion(self, widget, event):
        if not self._press or not self._xform:
            return False
        x0, y0, region_snapshot, members = self._press
        if self._drag is None:
            if abs(event.x - x0) < DRAG_THRESHOLD and \
                    abs(event.y - y0) < DRAG_THRESHOLD:
                return True
            self._drag = True
        g = self._active_group()
        if not g or frozenset(g["monitors"]) != members or not self.edit_image:
            return True
        dims = self._img_dims(self.edit_image)
        if not dims:
            return True
        s = self._xform[0]
        _, _, dref, rw, rh = self._group_geom(g)
        dpx = (event.x - x0) / s * dref
        dpy = (event.y - y0) / s * dref
        panned = st.pan_by(region_snapshot, dpx, dpy, dims, rw, rh)
        panned, self._snapped_axes = st.snap_pan(panned, dims, rw, rh, SNAP_PHYS)
        g["region"] = panned
        self._mark_dirty()
        return True

    def on_button_release(self, widget, event):
        if event.button == 1 and self._press:
            self._press = None
            if self._drag:
                self._drag = None
                self._snapped_axes = set()
                self._layout_changed()
            return True
        return False

    def on_scroll(self, widget, event):
        if self.edit_mode or not self._xform:
            return False
        direction = 0
        if event.direction == Gdk.ScrollDirection.UP:
            direction = 1
        elif event.direction == Gdk.ScrollDirection.DOWN:
            direction = -1
        elif event.direction == Gdk.ScrollDirection.SMOOTH:
            ok, _, dy = event.get_scroll_deltas()
            if ok and dy:
                direction = -1 if dy > 0 else 1
        if not direction:
            return True
        mon = self._mon_at(event.x, event.y)
        if mon:
            self._on_monitor_activated(mon.name)
            if mon.name not in self.selected:
                self.selected = {mon.name}
        g = self._active_group()
        if not g:
            return True
        shift = bool(event.state & _CLEAN_MASK & Gdk.ModifierType.SHIFT_MASK)
        base = SCROLL_ZOOM_FINE if shift else SCROLL_ZOOM
        factor = base if direction > 0 else 1 / base
        # anchor: cursor position in region-phys coords
        s, ox, oy, min_x, min_y = self._xform
        lx = (event.x - ox) / s + min_x
        ly = (event.y - oy) / s + min_y
        glx, gly, dref, rw, rh = self._group_geom(g)
        anchor = ((lx - glx) * dref, (ly - gly) * dref)
        anchor = (max(0.0, min(rw, anchor[0])), max(0.0, min(rh, anchor[1])))
        self._zoom_active(factor, anchor)
        return True

    # ── live apply ────────────────────────────────────────────────────

    def _schedule_live_apply(self):
        if self._live_timer is not None:
            GLib.source_remove(self._live_timer)
        self._live_timer = GLib.timeout_add(LIVE_APPLY_MS, self._do_live_apply)

    def _do_live_apply(self):
        self._live_timer = None
        g = self._active_group()
        if not g or not self.edit_image:
            return False
        dims = self._img_dims(self.edit_image)
        pix = self._pixbuf(self.edit_image)
        if not dims or pix is None:
            return False
        os.makedirs(PREVIEW_DIR, exist_ok=True)
        members = [self.mons_by_name[n] for n in g["monitors"]
                   if n in self.mons_by_name]
        lb = self.letterbox.get(self.edit_image, "#000000")
        for m in members:
            spec = member_crop(dims, g["region"], members, m, lb)
            ow, oh = max(1, m.pw // 2), max(1, m.ph // 2)
            surface = cairo.ImageSurface(cairo.FORMAT_RGB24, ow, oh)
            cr = cairo.Context(surface)
            self._paint_spec(cr, spec, dims, pix, 0, 0, ow, oh, lb)
            path = os.path.join(PREVIEW_DIR, f"live-{m.name}.png")
            surface.write_to_png(path)
            subprocess.run(
                ["awww", "img", "-o", m.name, path, "--transition-type", "none"],
                check=False, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=10)
            # What is on that screen now, which is not what the per-workspace
            # map says. Confirming has to reproduce this, not the map.
            self._live_state[m.name] = self.edit_image
        self._live_applied_any = True
        return False

    # ── edit mode / command display ───────────────────────────────────

    def _enter_edit_mode(self):
        self.edit_mode = True
        buf = self.cmd_view.get_buffer()
        buf.set_text(self._build_display_cmd())
        self.cmd_view.set_editable(True)
        self.cmd_view.set_cursor_visible(True)
        self.cmd_prefix_label.set_text(
            "Editing apply commands — Esc: done  ·  Ctrl+Enter: confirm:"
        )
        self.cmd_view.grab_focus()
        buf.place_cursor(buf.get_end_iter())

    def _exit_edit_mode(self):
        self.edit_mode = False
        self.cmd_edited = True
        self.cmd_view.set_editable(False)
        self.cmd_view.set_cursor_visible(False)
        self.cmd_prefix_label.set_text(
            "Apply commands (edited — Enter to run, any layout key to regenerate):"
        )
        self.darea.grab_focus()

    def _parse_edited_cmd(self):
        buf = self.cmd_view.get_buffer()
        text = buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)
        return [line.strip() for line in text.splitlines() if line.strip()]

    def _build_display_cmd(self):
        cmds = self._apply_cmds()
        if not cmds:
            return "# no changes yet — pan/zoom/group, then Enter applies"
        return "\n".join(cmds)

    def _update_cmd(self):
        if self.edit_mode:
            return
        if self.cmd_edited:
            self.cmd_edited = False
            self.cmd_prefix_label.set_text("Apply commands (to be run) — e: edit:")
        self.cmd_view.get_buffer().set_text(self._build_display_cmd())

    # ── drawing ───────────────────────────────────────────────────────

    def on_draw(self, widget, cr):
        alloc = widget.get_allocation()
        sw, sh = alloc.width, alloc.height

        cr.set_source_rgba(0.05, 0.05, 0.1, 0.92)
        cr.rectangle(0, 0, sw, sh)
        cr.fill()

        if not self.mons:
            return

        strip_h = self._draw_thumb_strip(cr, sw)

        # True-coordinate layout scaled to fit between strip and info area
        min_x = min(m.lx for m in self.mons)
        min_y = min(m.ly for m in self.mons)
        span_w = max(max(m.lx + m.lw for m in self.mons) - min_x, 1)
        span_h = max(max(m.ly + m.lh for m in self.mons) - min_y, 1)
        avail_h = sh * 0.80 - strip_h
        s = min(sw * 0.62 / span_w, avail_h * 0.72 / span_h)
        ox = (sw - span_w * s) / 2
        oy = strip_h + (avail_h - span_h * s) / 2
        self._xform = (s, ox, oy, min_x, min_y)

        def draw_box(m):
            return (ox + (m.lx - min_x) * s + BOX_GAP,
                    oy + (m.ly - min_y) * s + BOX_GAP,
                    m.lw * s - 2 * BOX_GAP, m.lh * s - 2 * BOX_GAP)

        # Image previews first (grouped so spans paint continuously)...
        painted = set()
        for image, groups in self._reality_groups():
            for g in groups:
                self._draw_group_preview(cr, g, image, draw_box)
                painted |= set(g["monitors"])
        # ...then chrome on top
        for m in self.mons:
            self._draw_monitor_chrome(cr, *draw_box(m), m)

        self._draw_info_area(cr, sw, sh)
        if self.preset_menu is not None:
            self._draw_preset_menu(cr, sw, sh)
        if self.lock_warning is not None:
            self._draw_lock_warning(cr, sw, sh)

    def _reality_groups(self):
        """[(image, groups-to-draw)] covering every monitor exactly once:
        the edit group previews the edit image; everything else previews its
        current wallpaper with its saved layout."""
        result = []
        active = self._active_group()
        active_set = set(active["monitors"]) if active else set()
        if active and self.edit_image:
            result.append((self.edit_image, [active]))
        by_image = {}
        for m in self.mons:
            if m.name in active_set:
                continue
            img = self.mon_image.get(m.name)
            if img:
                by_image.setdefault(img, set()).add(m.name)
        for img, names in by_image.items():
            groups = []
            for g in self._groups_for(img):
                sub = set(g["monitors"]) & names
                if not sub:
                    continue
                if sub == set(g["monitors"]):
                    groups.append(g)
                else:
                    # group partially hidden behind the edit group: draw the
                    # visible members with the same region config
                    groups.append({"monitors": sub,
                                   "region": g["region"]})
            result.append((img, groups))
        return result

    def _paint_spec(self, cr, spec, dims, pix, bx, by, bw, bh, letterbox):
        """Paint a CropSpec preview into rect (bx,by,bw,bh) — the same math
        the renderer uses, via the pixbuf (possibly downscaled)."""
        iw, ih = dims
        u0, v0, u1, v1 = spec.box
        f = pix.get_width() / iw  # pixbuf downscale factor
        cr.save()
        cr.rectangle(bx, by, bw, bh)
        cr.clip()
        # letterbox / tile background
        r, gcol, b = (int(letterbox[i:i + 2], 16) / 255 for i in (1, 3, 5))
        cr.set_source_rgb(r, gcol, b)
        cr.paint()
        cr.translate(bx, by)
        cr.scale(bw / ((u1 - u0) * f), bh / ((v1 - v0) * f))
        Gdk.cairo_set_source_pixbuf(cr, pix, -u0 * f, -v0 * f)
        pattern = cr.get_source()
        pattern.set_extend(cairo.Extend.REPEAT if spec.tile
                           else cairo.Extend.NONE)
        pattern.set_filter(cairo.Filter.GOOD)
        cr.paint()
        cr.restore()

    def _draw_group_preview(self, cr, g, image, draw_box):
        dims = self._img_dims(image)
        pix = self._pixbuf(image)
        members = [self.mons_by_name[n] for n in g["monitors"]
                   if n in self.mons_by_name]
        if not members:
            return
        active = self._active_group()
        is_edit = (active is not None and image == self.edit_image
                   and set(g["monitors"]) == set(active["monitors"]))
        lb = self.letterbox.get(image, "#000000")
        for m in members:
            bx, by, bw, bh = draw_box(m)
            if dims and pix:
                spec = member_crop(dims, g["region"], members, m, lb)
                self._paint_spec(cr, spec, dims, pix, bx, by, bw, bh, lb)
            else:
                cr.set_source_rgba(0.15, 0.15, 0.2, 0.9)
                cr.rectangle(bx, by, bw, bh)
                cr.fill()
            if not is_edit:
                cr.set_source_rgba(0, 0, 0, 0.45)
                cr.rectangle(bx, by, bw, bh)
                cr.fill()

    def _draw_monitor_chrome(self, cr, x, y, w, h, mon):
        name = mon.name
        is_sel = name in self.selected
        is_focused = name == self.focused_name
        active = self._active_group()
        in_active = active is not None and name in active["monitors"]

        if in_active:
            cr.set_source_rgba(0.2, 0.8, 1.0, 1.0)
            cr.set_line_width(4)
        elif is_sel:
            cr.set_source_rgba(0.2, 0.8, 1.0, 0.65)
            cr.set_line_width(3)
        elif is_focused:
            cr.set_source_rgba(0.4, 0.8, 0.4, 1.0)
            cr.set_line_width(3)
        else:
            cr.set_source_rgba(0.45, 0.45, 0.5, 1.0)
            cr.set_line_width(2.5)
        cr.rectangle(x, y, w, h)
        cr.stroke()
        if (in_active or is_sel) and is_focused:
            cr.set_source_rgba(0.4, 0.8, 0.4, 1.0)
            cr.set_line_width(2)
            cr.rectangle(x + 4, y + 4, w - 8, h - 8)
            cr.stroke()

        cr.select_font_face("Sans", 0, 0)

        # backing strip so text reads over imagery
        cr.set_source_rgba(0, 0, 0, 0.45)
        cr.rectangle(x, y, w, 24)
        cr.fill()

        idx = next((i for i, m in enumerate(self.mons) if m is mon), 0) + 1
        img = self.mon_image.get(name)
        parts = [f"[{idx}] {name}"]
        if img:
            parts.append(os.path.basename(img))
        ws = self.ws_active.get(name)
        if ws is not None:
            parts.append(f"ws {ws}")
        if is_focused:
            parts.append("focused")
        tag = "  ·  ".join(parts)
        cr.set_source_rgba(1, 1, 1, 0.9)
        cr.set_font_size(12)
        cr.move_to(x + 8, y + 16)
        cr.show_text(tag)

        # group badge, bottom-left
        g = st.group_of(self._groups_for(img), name) if img else None
        if in_active and self.edit_image:
            g = active
        if g and len(g["monitors"]) > 1:
            others = ", ".join(sorted(set(g["monitors"]) - {name}))
            badge = f"span with {others}"
        elif g and not st.is_default_region(g["region"]):
            badge = "custom placement"
        else:
            badge = None
        if badge:
            cr.set_source_rgba(0, 0, 0, 0.45)
            cr.rectangle(x, y + h - 22, w, 22)
            cr.fill()
            cr.set_source_rgba(0.5, 0.9, 1.0, 0.95)
            cr.set_font_size(11)
            cr.move_to(x + 8, y + h - 7)
            cr.show_text(badge)

    def _draw_thumb_strip(self, cr, sw):
        """Thumbnail row along the top; returns the strip height used."""
        self._thumb_hits = []
        if not self.backgrounds:
            return 20
        n = len(self.backgrounds)
        pad = 6
        tw_max = (sw - 60 - pad * (n - 1)) / n
        y = 18
        widths = []
        for path in self.backgrounds:
            t = self._thumb(path)
            widths.append(min(t.get_width() * 1.0, tw_max) if t else tw_max * 0.5)
        total = sum(widths) + pad * (n - 1)
        x = (sw - total) / 2
        for path, wdt in zip(self.backgrounds, widths):
            t = self._thumb(path)
            h = THUMB_H
            if t:
                scale = min(wdt / t.get_width(), 1.0)
                dw, dh = t.get_width() * scale, t.get_height() * scale
                cr.save()
                cr.translate(x, y + (THUMB_H - dh) / 2)
                cr.scale(scale, scale)
                Gdk.cairo_set_source_pixbuf(cr, t, 0, 0)
                cr.paint()
                cr.restore()
                wdt, h = dw, dh
            is_edit = path == self.edit_image
            is_extra = path in self.extras
            shown_on = [i + 1 for i, m in enumerate(self.mons)
                        if self.mon_image.get(m.name) == path]
            if is_edit:
                cr.set_source_rgba(0.2, 0.8, 1.0, 1.0)
                cr.set_line_width(3)
            elif shown_on:
                cr.set_source_rgba(1.0, 0.8, 0.2, 0.8)
                cr.set_line_width(1.5)
            elif is_extra:
                # Added by hand, not part of the theme: worth telling apart at
                # a glance, because using one switches a feature off.
                cr.set_source_rgba(0.75, 0.5, 1.0, 0.7)
                cr.set_line_width(1.5)
            else:
                cr.set_source_rgba(1, 1, 1, 0.25)
                cr.set_line_width(1)
            cr.rectangle(x, y + (THUMB_H - h) / 2, wdt, h)
            cr.stroke()
            # markers: monitor indices showing this image + layout dot
            label = "".join(str(i) for i in shown_on)
            if is_extra:
                label += " +"
            if self._has_saved_or_dirty_layout(path):
                label += " *"
            if label:
                cr.set_source_rgba(1, 1, 1, 0.7)
                cr.select_font_face("Sans", 0, 0)
                cr.set_font_size(10)
                cr.move_to(x + 2, y + THUMB_H + 12)
                cr.show_text(label.strip())
            self._thumb_hits.append((x, y + (THUMB_H - h) / 2, wdt, h, path))
            x += wdt + pad
        return y + THUMB_H + 24

    def _has_saved_or_dirty_layout(self, path):
        if path in self.dirty:
            return True
        if path in self.layouts:
            return st.serialize_layout(path, self.layouts[path]) is not None
        return os.path.isfile(store.sidecar_path(path))

    def _draw_info_area(self, cr, sw, sh):
        cr.select_font_face("Sans", 0, 0)
        bottom_y = sh - 30

        hint = ("Click: select+activate  ·  drag: pan  ·  scroll: zoom  ·  Ctrl+Click/1-9/0: multi"
                "  ·  g/u: group/ungroup  ·  Tab: next group  ·  f: fit mode  ·  z: reset"
                "  ·  [ ]: image  ·  o: add image  ·  p: presets  ·  Ctrl+S: save preset  ·  L: live"
                "  ·  Enter: apply  ·  Esc: cancel")
        cr.set_source_rgba(1, 1, 1, 0.45)
        cr.set_font_size(13)
        te = cr.text_extents(hint)
        cr.move_to((sw - te.width) / 2, bottom_y)
        cr.show_text(hint)

        bottom_y = sh - 118 - 14 * max(0, len(self.dirty) - 1)

        warn = self._mixed_span_warning()
        if warn:
            cr.set_source_rgba(1.0, 0.65, 0.3, 0.95)
            cr.set_font_size(15)
            te = cr.text_extents(warn)
            cr.move_to((sw - te.width) / 2, bottom_y)
            cr.show_text(warn)
            bottom_y -= 26

        if self.flash_msg:
            cr.set_source_rgba(1.0, 0.85, 0.3, 0.95)
            cr.set_font_size(15)
            te = cr.text_extents(self.flash_msg)
            cr.move_to((sw - te.width) / 2, bottom_y)
            cr.show_text(self.flash_msg)
            bottom_y -= 26

        g = self._active_group()
        if g and self.edit_image:
            r = g["region"]
            mons_lbl = "+".join(sorted(g["monitors"]))
            kind = "span" if len(g["monitors"]) > 1 else "solo"
            status = (f"Editing {os.path.basename(self.edit_image)}"
                      f"{' (pinned)' if self.image_pinned else ''}"
                      f"  ·  {mons_lbl} {kind}"
                      f"  ·  {r.get('mode', 'fill')}"
                      f"  ·  zoom {r.get('zoom', 1.0):.2f}"
                      f"  ·  pan {r.get('pan', [0, 0])[0]:+.3f},{r.get('pan', [0, 0])[1]:+.3f}"
                      f"  ·  live-apply {'ON' if self.live_apply else 'off'}")
        else:
            status = "No active group — click a monitor"
        cr.set_source_rgba(1, 1, 1, 0.7)
        cr.set_font_size(16)
        te = cr.text_extents(status)
        cr.move_to((sw - te.width) / 2, bottom_y)
        cr.show_text(status)

    def _draw_lock_warning(self, cr, sw, sh):
        """Last stop before an added image takes over the desktop. It says
        what gets switched off, what that buys, and what it costs later."""
        names = ", ".join(os.path.basename(p) for p in self.lock_warning)
        lines = [
            ("Workspace backgrounds will be turned OFF", 20, (1.0, 0.75, 0.3)),
            (f"{names} is not a theme image, so the per-workspace",
             15, (1, 1, 1)),
            ("map would paint over it on the next workspace switch.",
             15, (1, 1, 1)),
            ("", 8, (1, 1, 1)),
            ("Applying locks the current backgrounds in place.", 15, (1, 1, 1)),
            ("Switching the feature back on discards this arrangement",
             15, (1, 1, 1)),
            ("and every saved layout, and returns to the theme.",
             15, (1, 1, 1)),
            ("", 8, (1, 1, 1)),
            ("Enter: apply and turn it off   ·   Esc: back to editing",
             15, (0.4, 0.9, 1.0)),
        ]
        pad = 26
        widths, heights = [], []
        for text, size, _ in lines:
            cr.set_font_size(size)
            widths.append(cr.text_extents(text).width if text else 0)
            heights.append(size + 8)
        bw = max(widths) + pad * 2
        bh = sum(heights) + pad * 2
        bx, by = (sw - bw) / 2, (sh - bh) / 2
        cr.set_source_rgba(0.08, 0.06, 0.02, 0.97)
        cr.rectangle(bx, by, bw, bh)
        cr.fill()
        cr.set_source_rgba(1.0, 0.65, 0.2, 0.9)
        cr.set_line_width(2)
        cr.rectangle(bx, by, bw, bh)
        cr.stroke()
        y = by + pad
        for (text, size, rgb), h in zip(lines, heights):
            y += h
            if not text:
                continue
            cr.set_font_size(size)
            cr.set_source_rgba(*rgb, 0.95)
            cr.move_to(bx + (bw - cr.text_extents(text).width) / 2, y - 6)
            cr.show_text(text)

    def _draw_preset_menu(self, cr, sw, sh):
        menu = self.preset_menu
        names = menu["names"]
        row_h, pad = 30, 18
        w = max([cr.text_extents(n).width for n in names] + [220]) + 2 * pad + 40
        h = len(names) * row_h + 2 * pad + 34
        x, y = (sw - w) / 2, (sh - h) / 2
        cr.set_source_rgba(0.08, 0.08, 0.14, 0.97)
        cr.rectangle(x, y, w, h)
        cr.fill()
        cr.set_source_rgba(0.2, 0.8, 1.0, 0.9)
        cr.set_line_width(2)
        cr.rectangle(x, y, w, h)
        cr.stroke()
        cr.set_source_rgba(1, 1, 1, 0.85)
        cr.select_font_face("Sans", 0, 0)
        cr.set_font_size(15)
        title = f"Presets → {os.path.basename(self.edit_image or '?')}   (Enter: apply · d: delete · Esc)"
        cr.move_to(x + pad, y + pad + 12)
        cr.show_text(title)
        for i, name in enumerate(names):
            ry = y + pad + 34 + i * row_h
            if i == menu["sel"]:
                cr.set_source_rgba(0.2, 0.8, 1.0, 0.25)
                cr.rectangle(x + 6, ry - 20, w - 12, row_h - 4)
                cr.fill()
            cr.set_source_rgba(1, 1, 1, 0.9)
            cr.set_font_size(14)
            cr.move_to(x + pad, ry)
            cr.show_text(f"{i + 1}. {name}")


def main():
    # The Wayland app id GTK reports comes from the program name, and the
    # window rule that floats this thing keys off it.
    GLib.set_prgname(APP_ID)
    GLib.set_application_name("Background Layout")
    hypr_mons = _query_hypr_monitors()
    mons = [m for m in mons_from_hyprctl(hypr_mons) if not m.disabled]
    if not mons:
        print("No monitors found", file=sys.stderr)
        sys.exit(1)

    preselect = None
    for hm in hypr_mons:
        if hm.get("focused"):
            preselect = hm.get("name")
            break

    editor = BackgroundEditor(mons, get_backgrounds(), preselect, read_extras())
    Gtk.main()

    if editor.result is not None:
        for cmd in editor.result:
            print(cmd)
        sys.exit(0)
    sys.exit(1)


if __name__ == "__main__":
    main()
