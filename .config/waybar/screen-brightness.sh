#!/bin/bash
B=$(brightnessctl -m 2>/dev/null | cut -d, -f4 | tr -d '%')
if [ -z "$B" ]; then
  echo '{"text": "", "class": "hidden"}'
else
  echo "{\"text\": \"󰖨 ${B}%\", \"tooltip\": \"Brightness: ${B}%\"}"
fi
