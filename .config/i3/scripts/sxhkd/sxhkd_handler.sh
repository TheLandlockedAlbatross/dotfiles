#!/bin/bash

key="$1"
ws_display="$2"

# Set up i3 workspace bindings
screen_count=$(i3-msg -t get_outputs | grep -o '"active":true' | wc -l)
ws_icons=("" "󰃢" "" "󱎓" "󰙽" "󱄢" "󰴒" "󰨈" "" "󱋆" "󰠟" "" "" "" "" "󰛳" "" "󰎤" "󰎧" "󰎪" "" "󰁯" "" "󰡶" "")
ws_keys=(1 2 3 4 5 6 7 8 9 0 minus equal q w e r t y u i o p bracketleft bracketright backslash)
declare -A ws_map
offset=$(( ws_display * 25 ))
for i in "${!ws_keys[@]}"; do
    ws_key="${ws_keys[$i]}"
    ws_icon="${ws_icons[$i]}"
    ws_num=$(( i + 1 + offset ))
    ws_map["$ws_key"]="${ws_num} ${ws_icon} "
done

# If the key exists in our map, switch workspace and run your handler
if [[ -n "${ws_map[$key]}" ]]; then
    i3-msg workspace "${ws_map[$key]}"
fi

# 1. Map key name to keycode
keycode=$(xmodmap -pke | grep -E "= $key( |$)" | head -n 1 | awk '{print $2}')

if [ -z "$keycode" ]; then
    echo "Error: Key '$key' not found."
fi

# 2. Setup pathjjjjs
lock_file="/tmp/key_${keycode}_lock"
proc_file="/tmp/key_${keycode}_proc"

# 3. Arm the trigger and clear old listeners
sleep 0.5
echo touch "$lock_file"
touch "$lock_file"
pkill -f "xinput test-xi2 --root 3"

# 4. Run listener
# timeout kills xinput after 1s, breaking the pipe so gawk exits cleanly.
timeout 3s xinput test-xi2 --root 3 | gawk -v k="$keycode" '
/RawKeyRelease/ {
    getline
    while (getline > 0) {
        if ($1 == "detail:") {
            if ($2 == k) {
                cmd_mv = "mv /tmp/key_" k "_lock /tmp/key_" k "_proc 2>/dev/null"
                if (system(cmd_mv) == 0) {
                    sleep 1
                    system("~/.config/i3/scripts/open_default_programs/open_default_programs.sh 1")
                    system("rm -f /tmp/key_" k "_proc")
                    exit
                }
            }
            break
        }
    }
}'
