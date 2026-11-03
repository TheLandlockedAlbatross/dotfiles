#!/bin/bash
# Super+Alt+W: close every window in the active window's Hyprland group (just
# the active window when it is not grouped). Plain Super+W closes one window.

win=$(hyprctl activewindow -j 2>/dev/null)
[[ -z $win || $win == "{}" ]] && exit 0

mapfile -t members < <(jq -r '.grouped[]? // empty' <<<"$win")
if (( ${#members[@]} <= 1 )); then
  exec hyprctl dispatch killactive
fi

for addr in "${members[@]}"; do
  hyprctl dispatch closewindow "address:$addr" >/dev/null
done
