#!/bin/bash
STATE_FILE="/tmp/waybar-poll-rate"
STEPS=("0.1" "0.25" "0.5" "1" "2" "3" "4" "5" "6" "7" "8" "9" "10" "30" "60")

current_idx=$(cat "$STATE_FILE" 2>/dev/null || echo 6)
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

    # Rewrite all interval values in waybar config
    config="$HOME/.config/waybar/config.jsonc"
    # Convert to integer for interval (minimum 1)
    interval=$(awk -v v="$val" 'BEGIN { i = int(v); if (i < 1) i = 1; print i }')
    sed -i "s/\"interval\": *[0-9]*/\"interval\": $interval/g" "$config"

    omarchy-restart-waybar &
    break
  fi
done
