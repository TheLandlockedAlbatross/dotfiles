#!/bin/bash
# SketchyBar plugin: mirror sudo-toggle state.
# Armed when /etc/sudoers.d/sudo-nopasswd exists.
if [ -f /etc/sudoers.d/sudo-nopasswd ]; then
  sketchybar --set "$NAME" icon=🔓 label="Sudo Armed" label.color=0xffff453a
else
  sketchybar --set "$NAME" icon=🔒 label="Sudo Locked" label.color=0xff34c759
fi
