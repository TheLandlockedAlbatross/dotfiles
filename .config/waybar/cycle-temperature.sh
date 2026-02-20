#!/bin/bash
T=$(hyprctl hyprsunset temperature 2>/dev/null)
dir="${1:--500}"
next=$(( T + dir ))
if [ "$next" -lt 1000 ]; then
  next=10000
elif [ "$next" -gt 10000 ]; then
  next=1000
fi
hyprctl hyprsunset temperature "$next"
