#!/bin/bash
# wttr.in auto-locates by IP. Keep the previous reading if the fetch fails.
w=$(curl -fsS --max-time 5 'https://wttr.in/?m&format=%c+%t' 2>/dev/null)
if [ -n "$w" ] && ! echo "$w" | grep -qi "unknown\|sorry"; then
  sketchybar --set "$NAME" icon="" label="$w"
fi
