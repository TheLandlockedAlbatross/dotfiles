#!/bin/bash
# Reposition an active monitor relative to other displays.
# Shows a picker menu if 2+ monitors are active.
# With a monitor name as $1 (or "focused"), skips the menu and goes straight to
# the placement picker for that display.
# Discovers monitors dynamically via wlr-randr.
# Picker outputs TWO config lines (current + new) and writes monitors.conf.

active_count=$(wlr-randr --json | jq '[.[] | select(.enabled == true)] | length')

if (( active_count <= 1 )); then
    swayosd-client --custom-icon dialog-information --custom-message "Need 2+ active monitors to configure layout"
    exit 1
fi

target="$1"
[[ "$target" == "focused" ]] && target=$(hyprctl monitors -j | jq -r '.[] | select(.focused == true) | .name')

if [[ -n "$target" ]]; then
    if ! wlr-randr --json | jq -e --arg n "$target" '.[] | select(.enabled == true and .name == $n)' >/dev/null; then
        swayosd-client --custom-icon dialog-information --custom-message "$target is not an active monitor"
        exit 1
    fi
    choice="$target"
else
    # Build menu of active monitors
    menu=""
    while IFS= read -r name; do
        menu+="$name"$'\n'
    done < <(wlr-randr --json | jq -r '.[] | select(.enabled == true) | .name')

    choice=$(echo -n "$menu" | sed '/^$/d' | walker -d -p "Reposition monitor") || exit 0
fi

PICKER="$(dirname "$0")/monitor-picker.py"

if PICKED_CONFIGS=$(python3 "$PICKER" "$choice" 2>/dev/null); then
    while IFS= read -r config; do
        [[ -n "$config" ]] && hyprctl keyword monitor "$config"
    done <<< "$PICKED_CONFIGS"
    swayosd-client --custom-icon video-display --custom-message "$choice repositioned"
else
    swayosd-client --custom-icon dialog-information --custom-message "Repositioning cancelled"
fi
