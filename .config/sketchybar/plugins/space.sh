#!/bin/bash
# Per-workspace item: bold white when focused, dim regular when non-empty,
# hidden otherwise. FOCUSED_WORKSPACE is set by the aerospace trigger.
AEROSPACE=/opt/homebrew/bin/aerospace
i="${NAME#space.}"
focused="${FOCUSED_WORKSPACE:-$($AEROSPACE list-workspaces --focused 2>/dev/null)}"

if [ "$i" = "$focused" ]; then
  sketchybar --set "$NAME" drawing=on \
    label.font=".SF NS:Bold:13.0" label.color=0xffffffff
elif $AEROSPACE list-workspaces --monitor all --empty no 2>/dev/null | grep -qx "$i"; then
  sketchybar --set "$NAME" drawing=on \
    label.font=".SF NS:Regular:13.0" label.color=0x99ffffff
else
  sketchybar --set "$NAME" drawing=off
fi
