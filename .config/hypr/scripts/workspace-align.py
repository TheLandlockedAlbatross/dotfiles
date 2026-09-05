#!/usr/bin/env python3
"""Align picker: type a slot, see where every display would land, press Enter.

Each display owns one decade of ten workspaces (see workspace-map.sh), so slot
3 means workspace 3 on one display, 13 on the next, and so on. This asks for
the slot and previews the real workspace numbers as you type, because the
mapping depends on which panel owns which decade and that is not something to
work out in your head.

  Digits    pick the slot; 0 is the tenth, as on the digit row
  Enter     align, using the slot already in use when the box is empty
  Esc       leave everything alone

The alignment itself is workspace-map.sh's job; this only chooses the number.
"""

import os
import subprocess
import sys

import gi
gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

APP_ID = "omarchy.workspace-align"
WS_MAP = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "workspace-map.sh")

CSS = b"""
window { background-color: #12141c; }
#title { color: #7fd8ff; font-size: 15px; font-weight: bold; }
#hint { color: rgba(255,255,255,0.45); font-size: 12px; }
#warn { color: #ffb347; font-size: 13px; }
entry { background: #1c2030; color: #ffffff; border: 1px solid #2f3550;
        font-size: 22px; padding: 6px 10px; }
label.mon  { color: rgba(255,255,255,0.75); font-family: monospace; font-size: 14px; }
label.from { color: rgba(255,255,255,0.45); font-family: monospace; font-size: 14px; }
label.to   { color: #7fd8ff; font-family: monospace; font-size: 16px; font-weight: bold; }
label.skip { color: rgba(255,255,255,0.35); font-family: monospace; font-size: 13px; }
label.here { color: #7ae08a; }
"""


# ── data ──────────────────────────────────────────────────────────────

def read_preview():
    """(mode, size, [(monitor, first_workspace_of_its_decade_or_None)])."""
    try:
        out = subprocess.run([WS_MAP, "preview"], capture_output=True,
                             text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return "unknown", 10, []
    mode, size, rows = "unknown", 10, []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        key, val = parts
        if key == "mode":
            mode = val
        elif key == "size":
            size = int(val) if val.isdigit() else 10
        else:
            rows.append((key, int(val) if val.isdigit() else None))
    return mode, size, rows


def read_monitors():
    """({monitor: active workspace id}, focused monitor name)."""
    import json
    try:
        out = subprocess.run(["hyprctl", "monitors", "-j"],
                             capture_output=True, text=True, timeout=10).stdout
        mons = json.loads(out)
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}, None
    active, focused = {}, None
    for m in mons:
        active[m.get("name")] = (m.get("activeWorkspace") or {}).get("id")
        if m.get("focused"):
            focused = m.get("name")
    return active, focused


# ── pure logic (unit tested) ──────────────────────────────────────────

def parse_slot(text, size):
    """The slot a typed string means, or None if it means nothing yet.

    0 is the tenth slot, the same trick the digit row plays, so the keyboard
    and this box agree about what the bottom key does."""
    text = text.strip()
    if not text or not text.isdigit():
        return None
    value = int(text)
    if value == 0:
        return size
    return value if 1 <= value <= size else None


def slot_in_use(active, focused, rows, size):
    """The slot the focused display is already on, for an empty box. Falls back
    to the first slot when it is somewhere outside the scheme, matching what
    `workspace-map.sh align` does with no argument."""
    ws = active.get(focused)
    if not isinstance(ws, int) or ws < 1:
        return 1
    top = max((base + size - 1 for _, base in rows if base), default=0)
    if ws > top:
        return 1
    return (ws - 1) % size + 1


def preview_rows(rows, active, slot, size):
    """[(monitor, current workspace, target workspace or None)] for a slot.

    A display that owns no decade gets None: align leaves those alone rather
    than dragging a borrowed decade along with the rest."""
    out = []
    for name, base in rows:
        target = base + slot - 1 if base and 1 <= slot <= size else None
        out.append((name, active.get(name), target))
    return out


# ── window ────────────────────────────────────────────────────────────

class AlignPicker(Gtk.Window):
    def __init__(self, mode, size, rows, active, focused):
        super().__init__(title="Align displays")
        self.set_name(APP_ID)
        self.mode, self.size, self.rows = mode, size, rows
        self.active, self.focused = active, focused
        self.result = None

        css = Gtk.CssProvider()
        css.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), css,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_margin_top(18)
        box.set_margin_bottom(18)
        box.set_margin_start(22)
        box.set_margin_end(22)
        self.add(box)

        title = Gtk.Label(label="Align displays to a slot")
        title.set_name("title")
        title.set_xalign(0)
        box.pack_start(title, False, False, 0)

        self.entry = Gtk.Entry()
        self.entry.set_max_length(2)
        self.entry.set_placeholder_text(f"1-{size}")
        self.entry.set_width_chars(4)
        self.entry.set_alignment(0.5)
        self.entry.connect("changed", self._on_changed)
        self.entry.connect("activate", self._on_activate)
        box.pack_start(self.entry, False, False, 0)

        self.grid = Gtk.Grid(column_spacing=12, row_spacing=4)
        box.pack_start(self.grid, False, False, 4)

        self.hint = Gtk.Label()
        self.hint.set_name("hint")
        self.hint.set_xalign(0)
        box.pack_start(self.hint, False, False, 0)

        self.connect("key-press-event", self._on_key)
        self.connect("destroy", Gtk.main_quit)
        self.show_all()
        self.entry.grab_focus()
        self._refresh()
        self._poll_id = GLib.timeout_add(1000, self._on_poll)

    # Displays come and go while this is open, and a preview of where they
    # would land is worthless if it is describing a set that has changed.
    # Cheap path first: the workspace numbers move constantly, the set of
    # displays almost never, and only the latter needs the script re-run.
    def _on_poll(self):
        active, focused = read_monitors()
        if set(active) != set(self.active):
            self.mode, self.size, self.rows = read_preview()
        elif (active, focused) == (self.active, self.focused):
            return True
        self.active, self.focused = active, focused
        self._refresh()
        return True

    # Redrawn from scratch on every keystroke: four rows of labels is cheaper
    # than keeping widget state in step with the typing.
    def _refresh(self):
        for child in self.grid.get_children():
            self.grid.remove(child)

        if self.mode != "decade":
            warn = Gtk.Label(label="Needs the one-decade-per-display layout")
            warn.set_name("warn")
            warn.set_xalign(0)
            self.grid.attach(warn, 0, 0, 3, 1)
            self.hint.set_text("Esc closes  ·  Super+E cycles the layout back")
            self.grid.show_all()
            return

        if not self.rows:
            gone = Gtk.Label(label="No displays to align")
            gone.set_name("warn")
            gone.set_xalign(0)
            self.grid.attach(gone, 0, 0, 3, 1)
            self.hint.set_text("Esc closes")
            self.grid.show_all()
            return

        typed = parse_slot(self.entry.get_text(), self.size)
        slot = typed if typed is not None else slot_in_use(
            self.active, self.focused, self.rows, self.size)

        for row, (name, current, target) in enumerate(
                preview_rows(self.rows, self.active, slot, self.size)):
            lbl = Gtk.Label(label=name)
            lbl.set_xalign(0)
            lbl.get_style_context().add_class("mon")
            if name == self.focused:
                lbl.get_style_context().add_class("here")
            self.grid.attach(lbl, 0, row, 1, 1)

            frm = Gtk.Label(label=f"{current if current is not None else '-'}  →")
            frm.set_xalign(1)
            frm.get_style_context().add_class("from")
            self.grid.attach(frm, 1, row, 1, 1)

            if target is None:
                to = Gtk.Label(label="unchanged (no decade of its own)")
                to.get_style_context().add_class("skip")
            else:
                to = Gtk.Label(label=str(target))
                to.get_style_context().add_class("to")
            to.set_xalign(0)
            self.grid.attach(to, 2, row, 1, 1)

        text = self.entry.get_text().strip()
        if text and typed is None:
            self.hint.set_text(f"{text} is not a slot  ·  pick 1-{self.size}"
                               f"  ·  0 means {self.size}")
        elif typed is None:
            self.hint.set_text(f"slot {slot}, the one in use  ·  "
                               f"type 1-{self.size} to change it  ·  Enter applies")
        else:
            self.hint.set_text(f"slot {slot}  ·  Enter applies  ·  Esc cancels")
        self.grid.show_all()

    def _on_changed(self, _entry):
        self._refresh()

    def _on_activate(self, _entry):
        if self.mode != "decade":
            return
        text = self.entry.get_text().strip()
        if text and parse_slot(text, self.size) is None:
            return
        self.result = text
        self.destroy()

    def _on_key(self, _widget, event):
        if Gdk.keyval_name(event.keyval) == "Escape":
            self.result = None
            self.destroy()
            return True
        return False


def main():
    GLib.set_prgname(APP_ID)
    GLib.set_application_name("Align displays")
    mode, size, rows = read_preview()
    if not rows:
        print("no displays to align", file=sys.stderr)
        sys.exit(1)
    active, focused = read_monitors()
    win = AlignPicker(mode, size, rows, active, focused)
    Gtk.main()
    if win.result is None:
        sys.exit(1)
    cmd = [WS_MAP, "align"] + ([win.result] if win.result else [])
    subprocess.run(cmd, check=False, timeout=30)


if __name__ == "__main__":
    main()
