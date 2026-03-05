#!/bin/bash
# Toggle screen temperature/brightness between compact (stacked) and expanded (independent) waybar modules

FLAG="/tmp/waybar-screen-expanded"
CONFIG="$HOME/.config/waybar/config.jsonc"
STYLE="$HOME/.config/waybar/style.css"

COMPACT='#custom-screen-temperature,
#custom-screen-brightness {
  font-size: 7px;
  padding: 0;
  margin: 0;
}'

EXPANDED='#custom-screen-temperature,
#custom-screen-brightness {
  font-size: 12px;
  min-width: 12px;
  margin: 0 7.5px;
}'

swap_css() {
  python3 -c "
import sys
old, new, path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f: t = f.read()
with open(path, 'w') as f: f.write(t.replace(old, new))
" "$1" "$2" "$STYLE"
}

if [[ -f "$FLAG" ]]; then
  # Collapse back to compact stacked group
  sed -i '/modules-right/,/]/{s/"custom\/screen-temperature", "custom\/screen-brightness"/"group\/screen-display"/}' "$CONFIG"
  swap_css "$EXPANDED" "$COMPACT"
  rm "$FLAG"
else
  # Expand into independent full-size modules
  sed -i '/modules-right/,/]/{s/"group\/screen-display"/"custom\/screen-temperature", "custom\/screen-brightness"/}' "$CONFIG"
  swap_css "$COMPACT" "$EXPANDED"
  touch "$FLAG"
fi

omarchy-restart-waybar &
