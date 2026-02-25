#!/bin/bash
# Toggle a Hyprland monitor on/off by name.
# Usage: monitor-toggle.sh [monitor-name]
# All monitors are discovered dynamically via wlr-randr (no hardcoded values).
# Safety: refuses to disable the last active monitor.

OVERRIDE_FLAG="/tmp/hypr-monitor-manual"
MONITORS_CONF="$HOME/.config/hypr/monitors.conf"

MONITOR="$1"
if [[ -z "$MONITOR" ]]; then
    # No argument — discover all connected monitors and show menu with status
    menu=""
    while IFS=$'\t' read -r name enabled; do
        if [[ "$enabled" == "true" ]]; then
            menu+="$name (on)"$'\n'
        else
            menu+="$name (off)"$'\n'
        fi
    done < <(wlr-randr --json | jq -r '.[] | [.name, (.enabled | tostring)] | @tsv')

    if [[ -z "$menu" ]]; then
        swayosd-client --custom-icon dialog-warning --custom-message "No monitors found"
        exit 1
    fi

    choice=$(echo -n "$menu" | sed '/^$/d' | walker -d -p "Toggle monitor") || exit 0
    MONITOR="${choice%% (*}"
fi

# Verify the monitor exists
if ! wlr-randr --json | jq -e ".[] | select(.name == \"$MONITOR\")" > /dev/null 2>&1; then
    echo "Unknown monitor: $MONITOR" >&2
    exit 1
fi

# Count active monitors and check if target is active
active_count=$(hyprctl monitors -j | jq '[.[] | select(.disabled == false)] | length')
is_active=$(hyprctl monitors -j | jq -r ".[] | select(.name == \"$MONITOR\" and .disabled == false) | .name")

if [[ -n "$is_active" ]]; then
    # Monitor is active — try to disable it
    if (( active_count <= 1 )); then
        swayosd-client --custom-icon dialog-warning --custom-message "Can't disable $MONITOR — it's the only active display"
        exit 1
    fi
    hyprctl keyword monitor "$MONITOR, disable"
    # Persist to monitors.conf
    python3 -c "
import os, sys
name, conf = sys.argv[1], os.path.expanduser('~/.config/hypr/monitors.conf')
lines = open(conf).readlines()
out = [f'monitor = {name}, disable\n' if l.strip().startswith('monitor') and '= ' + name in l else l for l in lines]
if not any('= ' + name in l for l in lines if l.strip().startswith('monitor')):
    out.append(f'monitor = {name}, disable\n')
open(conf, 'w').writelines(out)
" "$MONITOR"
    touch "$OVERRIDE_FLAG"
    swayosd-client --custom-icon video-display --custom-message "$MONITOR disabled"
else
    # Monitor is disabled or not listed — launch picker for placement
    # Picker outputs TWO config lines (current + new) and writes monitors.conf
    PICKER="$(dirname "$0")/monitor-picker.py"
    if PICKED_CONFIGS=$(python3 "$PICKER" "$MONITOR" 2>/dev/null); then
        while IFS= read -r config; do
            [[ -n "$config" ]] && hyprctl keyword monitor "$config"
        done <<< "$PICKED_CONFIGS"
        touch "$OVERRIDE_FLAG"
        swayosd-client --custom-icon video-display --custom-message "$MONITOR enabled"
    else
        swayosd-client --custom-icon dialog-information --custom-message "$MONITOR placement cancelled"
    fi
fi
