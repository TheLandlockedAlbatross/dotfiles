#!/bin/bash
source "$(dirname "$0")/brightness-lib.sh"

mon=$(target_monitor)
b=$(read_brightness "$mon")
if [[ -z "$b" ]]; then
  echo '{"text": "", "class": "hidden"}'
else
  echo "{\"text\": \"󰖨 ${b}%\", \"tooltip\": \"Brightness on ${mon}: ${b}%\"}"
fi
