#!/bin/bash
B=$(brightnessctl -m 2>/dev/null | cut -d, -f4 | tr -d '%')
dir="${1:--10}"
next=$(( B + dir ))
if [ "$next" -lt 0 ]; then
  next=100
elif [ "$next" -gt 100 ]; then
  next=0
fi
brightnessctl set "${next}%"
