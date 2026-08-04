#!/bin/bash
# Launch the whole-layout monitor editor (monitor-picker.py).
# All active monitors are shown and arrangeable at once; the focused monitor
# is preselected. Optional $1 preselects a specific monitor instead
# ("focused" resolves to the focused one for compatibility).
# The editor prints one config line per monitor on confirm and writes the
# full layout to monitors.conf; we apply the lines via hyprctl here.

target="$1"
[[ "$target" == "focused" ]] && target=$(hyprctl monitors -j | jq -r '.[] | select(.focused == true) | .name')

PICKER="$(dirname "$0")/monitor-picker.py"

if PICKED_CONFIGS=$(python3 "$PICKER" ${target:+"$target"} 2>/dev/null); then
    while IFS= read -r config; do
        [[ -n "$config" ]] && hyprctl keyword monitor "$config"
    done <<< "$PICKED_CONFIGS"
    swayosd-client --custom-icon video-display --custom-message "Monitor layout applied"
else
    swayosd-client --custom-icon dialog-information --custom-message "Monitor layout unchanged"
fi
