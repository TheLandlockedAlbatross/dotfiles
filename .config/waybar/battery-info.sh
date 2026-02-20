#!/bin/bash
{
  echo "――――――――― Battery Info ―――――――――"
  upower -i /org/freedesktop/UPower/devices/battery_BAT0 2>/dev/null \
    | grep -E '(state|energy:|energy-full:|energy-full-design|energy-rate|time to|percentage|capacity:|technology|charge-cycles|voltage:)' \
    | sed 's/^  *//'
} | omarchy-launch-walker --dmenu --nosearch --width 295 --minheight 1 --maxheight 630 -p "Battery" 2>/dev/null
