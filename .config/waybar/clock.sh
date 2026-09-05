#!/bin/bash
# omarchy 4 style clock: "dddd HH:mm" (e.g. "Friday 14:32"), left-click flips
# to the alternate "d MMMM Www yyyy" date view (state survives until clicked
# back). Right-click keeps the tz-select binding from the waybar config.
STATE="$HOME/.cache/waybar-clock-alt"

if [[ "$1" == "toggle" ]]; then
  if [[ -f "$STATE" ]]; then rm -f "$STATE"; else touch "$STATE"; fi
  exit 0
fi

if [[ -f "$STATE" ]]; then
  date "+%-d %B W%-V %Y"
else
  date "+%A %H:%M"
fi
