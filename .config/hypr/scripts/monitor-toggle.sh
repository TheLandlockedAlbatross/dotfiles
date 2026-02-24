#!/bin/bash
# Toggle a Hyprland monitor on/off by name.
# Usage: monitor-toggle.sh <monitor-name>
# Safety: refuses to disable the last active monitor.

OVERRIDE_FLAG="/tmp/hypr-monitor-manual"

# Monitor configs — add entries here to match monitors.conf
declare -A MONITOR_CONFIGS=(
    ["eDP-1"]="eDP-1, preferred, auto, 2"
    ["HDMI-A-1"]="HDMI-A-1, 3840x2160@120, 0x0, 2.4"
)

MONITOR="$1"
if [[ -z "$MONITOR" ]]; then
    # No argument — show a rofi dropdown of all known monitors with status
    MONITORS_JSON=$(hyprctl monitors all -j)
    menu=""
    for name in "${!MONITOR_CONFIGS[@]}"; do
        is_on=$(echo "$MONITORS_JSON" | jq -r ".[] | select(.name == \"$name\" and .disabled == false) | .name")
        if [[ -n "$is_on" ]]; then
            menu+="$name (on)"$'\n'
        else
            menu+="$name (off)"$'\n'
        fi
    done
    choice=$(echo -n "$menu" | sed '/^$/d' | walker -d -p "Toggle monitor") || exit 0
    MONITOR="${choice%% (*}"
fi

CONFIG="${MONITOR_CONFIGS[$MONITOR]}"
if [[ -z "$CONFIG" ]]; then
    echo "Unknown monitor: $MONITOR" >&2
    exit 1
fi

# Count active (non-disabled) monitors
active_count=$(hyprctl monitors -j | jq '[.[] | select(.disabled == false)] | length')

# Check if this monitor is currently active
is_active=$(hyprctl monitors -j | jq -r ".[] | select(.name == \"$MONITOR\" and .disabled == false) | .name")

if [[ -n "$is_active" ]]; then
    # Monitor is active — try to disable it
    if (( active_count <= 1 )); then
        swayosd-client --custom-icon dialog-warning --custom-message "Can't disable $MONITOR — it's the only active display"
        exit 1
    fi
    hyprctl keyword monitor "$MONITOR, disable"
    touch "$OVERRIDE_FLAG"
    swayosd-client --custom-icon video-display --custom-message "$MONITOR disabled"
else
    # Monitor is disabled or not listed — launch picker for placement
    PICKER="$(dirname "$0")/monitor-picker.py"
    if PICKED_CONFIG=$(python3 "$PICKER" "$MONITOR" 2>/dev/null); then
        hyprctl keyword monitor "$PICKED_CONFIG"
        touch "$OVERRIDE_FLAG"
        swayosd-client --custom-icon video-display --custom-message "$MONITOR enabled"
    else
        swayosd-client --custom-icon dialog-information --custom-message "$MONITOR placement cancelled"
    fi
fi
