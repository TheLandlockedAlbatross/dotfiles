#!/bin/bash
source "$(dirname "$0")/brightness-lib.sh"

mon=$(target_monitor)
b=$(read_brightness "$mon")
if [[ -z "$b" ]]; then
  echo '{"text": "", "class": "hidden"}'
  exit 0
fi

# On the internal panel, when the backlight is at its floor and we've dimmed
# further via gamma, show the gamma level (moon icon) instead.
if [[ "$mon" == "eDP-1" ]] && (( b == 0 )); then
  g=$(gamma_get)
  if (( g < 100 )); then
    echo "{\"text\": \"󰖔 ${g}%\", \"tooltip\": \"Sub-floor dim (gamma) on ${mon}: ${g}%\"}"
    exit 0
  fi
fi

echo "{\"text\": \"󰖨 ${b}%\", \"tooltip\": \"Brightness on ${mon}: ${b}%\"}"
