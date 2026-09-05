#!/bin/bash
# Launch the background layout editor (background-picker.py).
# The editor persists layout sidecars itself on confirm and prints the apply
# commands (engine renders + repaint) on stdout; we run them here.
#
# The layout system rides on awww/per-workspace backgrounds. Two states
# provide it: the feature switched on, or an arrangement the editor locked in
# place (feature off, awww still holding custom images). Anything else needs
# the feature switched on first — which discards customizations, so the toggle
# does the warning rather than this script doing it silently.

STATE_FILE=~/.local/state/omarchy/toggles/workspace-backgrounds
LOCK_MARK=/tmp/hypr-bg-locked
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f $STATE_FILE && ! -f $LOCK_MARK ]]; then
    "$SCRIPTS_DIR/workspace-backgrounds.sh" toggle
    if [[ ! -f $STATE_FILE ]]; then
        swayosd-client --custom-icon dialog-information --custom-message "Background layout editor needs workspace backgrounds on"
        exit 0
    fi
fi

if PICKED_CMDS=$(python3 "$SCRIPTS_DIR/background-picker.py" 2>/dev/null); then
    while IFS= read -r cmd; do
        [[ -n "$cmd" && "$cmd" != \#* ]] && bash -c "$cmd"
    done <<< "$PICKED_CMDS"
    swayosd-client --custom-icon preferences-desktop-wallpaper --custom-message "Background layout applied"
else
    swayosd-client --custom-icon dialog-information --custom-message "Background layout unchanged"
fi
