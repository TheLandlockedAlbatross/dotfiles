#!/bin/bash
STATE_FILE="/tmp/waybar-poll-rate"
STEPS=("0.1" "0.25" "0.5" "1" "2" "3" "4" "5" "6" "7" "8" "9" "10" "30" "60")

current_idx=$(cat "$STATE_FILE" 2>/dev/null || echo 3)
current_val=${STEPS[$current_idx]}

# Build menu with current value marked
menu=""
for i in "${!STEPS[@]}"; do
  v="${STEPS[$i]}"
  if [ "$i" -eq "$current_idx" ]; then
    menu+="► ${v}s\n"
  else
    menu+="  ${v}s\n"
  fi
done

choice=$(echo -e "$menu" | walker --dmenu -p "Poll rate (current: ${current_val}s)")
[ -z "$choice" ] && exit 0

# Extract the number from the choice
val=$(echo "$choice" | sed 's/[^0-9.]//g')

# Find matching index
for i in "${!STEPS[@]}"; do
  if [ "${STEPS[$i]}" = "$val" ]; then
    echo "$i" > "$STATE_FILE"

    # Nudge the omarchy-shell bar widgets to pick up the new cadence
    omarchy-shell -q tla.poll-rate refresh
    omarchy-shell -q tla.vpn refresh
    break
  fi
done
