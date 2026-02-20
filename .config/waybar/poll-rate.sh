#!/bin/bash
STATE_FILE="/tmp/waybar-poll-rate"
STEPS=(0.1 0.25 0.5 1 2 3 4 5 6 7 8 9 10 30 60)

[ -f "$STATE_FILE" ] || echo 7 > "$STATE_FILE"  # default index 7 = 5

idx=$(cat "$STATE_FILE")
val=${STEPS[$idx]}
printf '{"text": "󰓅 %s  ", "tooltip": "Poll rate in seconds of waybar items"}\n' "$val"
