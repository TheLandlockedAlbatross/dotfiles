#!/bin/bash
# Cycle screen temperature with wrap-around, show swayosd notification

temp=$(hyprctl hyprsunset temperature 2>/dev/null)
step="${1:--500}"
abs=${step#-}

if (( abs >= 500 )); then
  # Round toward step direction to nearest multiple (e.g. 4050 → 4000 on click, 4500 on right-click)
  if (( step < 0 )); then
    next=$(( (temp - 1) / abs * abs ))
  else
    next=$(( (temp + abs) / abs * abs ))
  fi
  # If already on a boundary, move one full step
  if (( next == temp )); then
    next=$(( temp + step ))
  fi
else
  next=$(( temp + step ))
fi

if (( next < 1000 )); then
  next=10000
elif (( next > 10000 )); then
  next=1000
fi

hyprctl hyprsunset temperature "$next"

if (( next < 3600 )); then
  icon="temperature-warm"
elif (( next <= 6000 )); then
  icon="temperature-normal"
else
  icon="temperature-cold"
fi

progress=$(awk "BEGIN { v = ($next - 1000) / 5500; v = v < 0 ? 0 : v > 1 ? 1 : v; printf \"%.2f\", v }")

~/.config/hypr/scripts/swayosd-focused.sh \
  --custom-icon "$icon" \
  --custom-progress "$progress" \
  --custom-progress-text "${next}K"
