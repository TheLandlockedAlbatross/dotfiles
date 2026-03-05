#!/bin/bash
# Cycle screen brightness with wrap-around, snapping clicks to nearest 10%

brightness=$(brightnessctl -m 2>/dev/null | cut -d, -f4 | tr -d '%')
step="${1:--10}"
abs=${step#-}

if (( abs >= 10 )); then
  # Round toward step direction to nearest multiple
  if (( step < 0 )); then
    next=$(( (brightness - 1) / abs * abs ))
  else
    next=$(( (brightness + abs) / abs * abs ))
  fi
  # If already on a boundary, move one full step
  if (( next == brightness )); then
    next=$(( brightness + step ))
  fi
else
  next=$(( brightness + step ))
fi

if (( next < 0 )); then
  next=100
elif (( next > 100 )); then
  next=0
fi

brightnessctl set "${next}%"
