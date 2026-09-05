#!/bin/bash
STATE_FILE="/tmp/waybar-poll-rate"
STEPS=(0.1 0.25 0.5 1 2 3 4 5 6 7 8 9 10 30 60)

[ -f "$STATE_FILE" ] || echo 3 > "$STATE_FILE"  # default index 3 = 1

idx=$(cat "$STATE_FILE")
val=${STEPS[$idx]}

# Plain value for the omarchy-shell bar widgets (tla.poll-rate / tla.vpn)
if [[ "$1" == "value" ]]; then
  echo "$val"
  exit 0
fi

printf '{"text": "󰓅 %s", "tooltip": "Poll rate in seconds of waybar items"}\n' "$val"
