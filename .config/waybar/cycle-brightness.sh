#!/bin/bash
# Cycle brightness on focused display with wrap-around, snapping clicks to nearest 10%.
source "$(dirname "$0")/brightness-lib.sh"

mon=$(target_monitor)
brightness=$(read_brightness "$mon")
[[ -z "$brightness" ]] && exit 0

step="${1:--10}"
abs=${step#-}

if (( abs >= 10 )); then
  if (( step < 0 )); then
    next=$(( (brightness - 1) / abs * abs ))
  else
    next=$(( (brightness + abs) / abs * abs ))
  fi
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

set_brightness "$mon" "$next" >/dev/null
show_osd "$mon" "$next"
