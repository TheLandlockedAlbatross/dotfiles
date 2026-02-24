#!/usr/bin/env python3
"""Interactive monitor placement picker using GTK3 + GtkLayerShell + Cairo.

Usage: monitor-picker.py <monitor-to-enable>
Outputs the hyprctl monitor config string on Enter, exits 1 on Esc/cancel.
"""

import json
import math
import subprocess
import sys

import gi
gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gdk, GLib, Gtk, GtkLayerShell

# Monitor configs — resolution, refresh rate, scale (mirrors monitor-toggle.sh)
MONITOR_DB = {
    "eDP-1":    {"width": 2560, "height": 1600, "rate": 180, "scale": 2.0,  "icon": "\U0001f4bb"},
    "HDMI-A-1": {"width": 3840, "height": 2160, "rate": 120, "scale": 2.4,  "icon": "\U0001f4fa"},
}

POSITIONS = ["below", "right", "above", "left"]
POSITION_ARROWS = {"below": "\u2193", "above": "\u2191", "left": "\u2190", "right": "\u2192"}


def get_active_monitor(exclude_name):
    """Get the currently active monitor info from hyprctl."""
    result = subprocess.run(
        ["hyprctl", "monitors", "-j"], capture_output=True, text=True, check=True
    )
    monitors = json.loads(result.stdout)
    for m in monitors:
        if not m.get("disabled", False) and m["name"] != exclude_name:
            return {
                "name": m["name"],
                "width": m["width"],
                "height": m["height"],
                "rate": round(m["refreshRate"]),
                "scale": m["scale"],
                "x": m["x"],
                "y": m["y"],
                "icon": MONITOR_DB.get(m["name"], {}).get("icon", "\U0001f5b5"),
            }
    # Fallback: return first active
    for m in monitors:
        if not m.get("disabled", False):
            return {
                "name": m["name"],
                "width": m["width"],
                "height": m["height"],
                "rate": round(m["refreshRate"]),
                "scale": m["scale"],
                "x": m["x"],
                "y": m["y"],
                "icon": MONITOR_DB.get(m["name"], {}).get("icon", "\U0001f5b5"),
            }
    return None


def logical_size(mon):
    """Logical pixel dimensions (res / scale)."""
    return mon["width"] / mon["scale"], mon["height"] / mon["scale"]


def calc_hypr_position(position, current, new):
    """Calculate Hyprland position coordinates for the new monitor."""
    cw, ch = logical_size(current)
    nw, nh = logical_size(new)
    cx, cy = current["x"], current["y"]
    if position == "right":
        return int(cx + cw), cy
    elif position == "left":
        return int(cx - nw), cy
    elif position == "below":
        return cx, int(cy + ch)
    elif position == "above":
        return cx, int(cy - nh)


class MonitorPicker(Gtk.Window):
    def __init__(self, current, new_mon):
        super().__init__(title="Monitor Picker")
        self.set_app_paintable(True)
        self.set_name("omarchy.monitor-picker")

        # State
        self.current = current
        self.new_mon = new_mon
        self.pos_index = 0  # start at "below"
        self.result = None

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

        # Drawing area
        self.darea = Gtk.DrawingArea()
        self.darea.connect("draw", self.on_draw)
        self.add(self.darea)

        # Events
        self.connect("key-press-event", self.on_key)
        self.connect("destroy", Gtk.main_quit)

        self.show_all()

    @property
    def position(self):
        return POSITIONS[self.pos_index]

    def on_key(self, widget, event):
        key = Gdk.keyval_name(event.keyval)
        if key == "Escape":
            Gtk.main_quit()
            return True
        elif key == "Return" or key == "KP_Enter":
            self.result = self.build_config()
            Gtk.main_quit()
            return True
        elif key == "Right":
            self.pos_index = POSITIONS.index("right")
        elif key == "Left":
            self.pos_index = POSITIONS.index("left")
        elif key == "Down":
            self.pos_index = POSITIONS.index("below")
        elif key == "Up":
            self.pos_index = POSITIONS.index("above")
        else:
            return False
        self.darea.queue_draw()
        return True

    def build_config(self):
        x, y = calc_hypr_position(self.position, self.current, self.new_mon)
        n = self.new_mon
        db = MONITOR_DB.get(n["name"], {})
        w = db.get("width", n["width"])
        h = db.get("height", n["height"])
        rate = db.get("rate", n["rate"])
        scale = db.get("scale", n["scale"])
        return f"{n['name']}, {w}x{h}@{rate}, {x}x{y}, {scale}"

    def on_draw(self, widget, cr):
        alloc = widget.get_allocation()
        sw, sh = alloc.width, alloc.height

        # Background
        cr.set_source_rgba(0.05, 0.05, 0.1, 0.88)
        cr.rectangle(0, 0, sw, sh)
        cr.fill()

        # Compute box sizes — scale monitors proportionally
        # Use ~12% of screen width for the larger monitor's width
        cur_lw, cur_lh = logical_size(self.current)
        new_lw, new_lh = logical_size(self.new_mon)
        max_logical = max(cur_lw, cur_lh, new_lw, new_lh)
        display_scale = (sw * 0.12) / max_logical

        cur_bw = cur_lw * display_scale
        cur_bh = cur_lh * display_scale
        new_bw = new_lw * display_scale
        new_bh = new_lh * display_scale

        # Gap between boxes
        gap = 20

        # Compute bounding box of both monitors to center them
        pos = self.position
        if pos == "right":
            total_w = cur_bw + gap + new_bw
            total_h = max(cur_bh, new_bh)
            cx = (sw - total_w) / 2
            cy = (sh - total_h) / 2
            cur_x, cur_y = cx, cy + (total_h - cur_bh) / 2
            new_x, new_y = cx + cur_bw + gap, cy + (total_h - new_bh) / 2
        elif pos == "left":
            total_w = new_bw + gap + cur_bw
            total_h = max(cur_bh, new_bh)
            cx = (sw - total_w) / 2
            cy = (sh - total_h) / 2
            new_x, new_y = cx, cy + (total_h - new_bh) / 2
            cur_x, cur_y = cx + new_bw + gap, cy + (total_h - cur_bh) / 2
        elif pos == "below":
            total_w = max(cur_bw, new_bw)
            total_h = cur_bh + gap + new_bh
            cx = (sw - total_w) / 2
            cy = (sh - total_h) / 2
            cur_x, cur_y = cx + (total_w - cur_bw) / 2, cy
            new_x, new_y = cx + (total_w - new_bw) / 2, cy + cur_bh + gap
        else:  # above
            total_w = max(cur_bw, new_bw)
            total_h = new_bh + gap + cur_bh
            cx = (sw - total_w) / 2
            cy = (sh - total_h) / 2
            new_x, new_y = cx + (total_w - new_bw) / 2, cy
            cur_x, cur_y = cx + (total_w - cur_bw) / 2, cy + new_bh + gap

        # Draw current monitor box
        self._draw_monitor_box(
            cr, cur_x, cur_y, cur_bw, cur_bh,
            self.current, border_color=(0.4, 0.8, 0.4), is_current=True,
        )

        # Draw new monitor box
        self._draw_monitor_box(
            cr, new_x, new_y, new_bw, new_bh,
            self.new_mon, border_color=(0.2, 0.8, 1.0), is_current=False,
        )

        # Direction arrow between boxes
        arrow = POSITION_ARROWS[pos]
        cr.set_source_rgba(1, 1, 1, 0.6)
        cr.select_font_face("Sans", 0, 0)
        cr.set_font_size(28)
        te = cr.text_extents(arrow)
        # Place arrow in the gap between boxes
        if pos in ("left", "right"):
            ax = (cur_x + cur_bw / 2 + new_x + new_bw / 2) / 2 - te.width / 2
            ay = (cur_y + cur_bh / 2 + new_y + new_bh / 2) / 2 + te.height / 2
        else:
            ax = (cur_x + cur_bw / 2 + new_x + new_bw / 2) / 2 - te.width / 2
            ay = (cur_y + cur_bh / 2 + new_y + new_bh / 2) / 2 + te.height / 2
        cr.move_to(ax, ay)
        cr.show_text(arrow)

        # Hint text at bottom
        hint = "Arrow keys to position  \u00b7  Enter to confirm  \u00b7  Esc to cancel"
        cr.set_source_rgba(1, 1, 1, 0.5)
        cr.set_font_size(16)
        te = cr.text_extents(hint)
        cr.move_to((sw - te.width) / 2, sh - 40)
        cr.show_text(hint)

        # Position label
        pos_label = f"Position: {pos.capitalize()}"
        cr.set_source_rgba(1, 1, 1, 0.7)
        cr.set_font_size(20)
        te = cr.text_extents(pos_label)
        cr.move_to((sw - te.width) / 2, sh - 70)
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

        # Label: current / new
        tag = "Current" if is_current else "New"
        cr.set_source_rgba(*border_color, 0.8)
        cr.select_font_face("Sans", 0, 0)
        cr.set_font_size(11)
        te = cr.text_extents(tag)
        cr.move_to(x + (w - te.width) / 2, y - 6)
        cr.show_text(tag)

        # Icon
        icon = mon.get("icon", "")
        cr.set_source_rgba(1, 1, 1, 0.9)
        cr.set_font_size(min(w, h) * 0.25)
        te = cr.text_extents(icon)
        cr.move_to(x + (w - te.width) / 2, y + h * 0.35)
        cr.show_text(icon)

        # Resolution label
        res = f"{mon['width']}x{mon['height']}@{mon['rate']}Hz"
        cr.set_source_rgba(1, 1, 1, 0.85)
        cr.set_font_size(min(w * 0.08, 13))
        te = cr.text_extents(res)
        cr.move_to(x + (w - te.width) / 2, y + h * 0.58)
        cr.show_text(res)

        # Device name
        cr.set_source_rgba(1, 1, 1, 0.6)
        cr.set_font_size(min(w * 0.07, 12))
        te = cr.text_extents(mon["name"])
        cr.move_to(x + (w - te.width) / 2, y + h * 0.72)
        cr.show_text(mon["name"])

        # Scale info
        scale_text = f"scale {mon['scale']}"
        lw, lh = logical_size(mon)
        logical_text = f"{int(lw)}x{int(lh)} logical"
        cr.set_source_rgba(1, 1, 1, 0.4)
        cr.set_font_size(min(w * 0.06, 10))
        te = cr.text_extents(scale_text)
        cr.move_to(x + (w - te.width) / 2, y + h * 0.83)
        cr.show_text(scale_text)
        te = cr.text_extents(logical_text)
        cr.move_to(x + (w - te.width) / 2, y + h * 0.93)
        cr.show_text(logical_text)


def main():
    if len(sys.argv) < 2:
        print("Usage: monitor-picker.py <monitor-to-enable>", file=sys.stderr)
        sys.exit(1)

    target_name = sys.argv[1]
    if target_name not in MONITOR_DB:
        print(f"Unknown monitor: {target_name}", file=sys.stderr)
        sys.exit(1)

    # Get info about the currently active monitor
    current = get_active_monitor(target_name)
    if not current:
        print("No active monitor found", file=sys.stderr)
        sys.exit(1)

    # Build new monitor info from DB
    db = MONITOR_DB[target_name]
    new_mon = {
        "name": target_name,
        "width": db["width"],
        "height": db["height"],
        "rate": db["rate"],
        "scale": db["scale"],
        "icon": db["icon"],
    }

    picker = MonitorPicker(current, new_mon)
    Gtk.main()

    if picker.result:
        print(picker.result)
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
