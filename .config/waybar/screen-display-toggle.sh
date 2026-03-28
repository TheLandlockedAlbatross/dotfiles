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

swap_config() {
  python3 -c "
import re, sys
mode, path = sys.argv[1], sys.argv[2]
with open(path) as f: t = f.read()

# Only modify inside modules-right array, not group definitions
mr = re.search(r'\"modules-right\"\s*:\s*\[([^\]]*)\]', t, re.DOTALL)
if not mr:
    sys.exit(1)

old_block = mr.group(1)

if mode == 'collapse':
    new_block = re.sub(
        r'\"custom/screen-temperature\",\s*\n\s*\"custom/screen-brightness\"',
        '\"group/screen-display\"',
        old_block
    )
elif mode == 'expand':
    def repl(m):
        indent = m.group(1)
        return indent + '\"custom/screen-temperature\",\n' + indent + '\"custom/screen-brightness\"'
    new_block = re.sub(r'([ \t]*)\"group/screen-display\"', repl, old_block)

t = t[:mr.start(1)] + new_block + t[mr.end(1):]
with open(path, 'w') as f: f.write(t)
" "$1" "$CONFIG"
}

if [[ -f "$FLAG" ]]; then
  # Collapse back to compact stacked group
  swap_config collapse
  swap_css "$EXPANDED" "$COMPACT"
  rm "$FLAG"
else
  # Expand into independent full-size modules
  swap_config expand
  swap_css "$COMPACT" "$EXPANDED"
  touch "$FLAG"
fi

omarchy-restart-waybar &
