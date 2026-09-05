#!/bin/bash

# Focus a window by address, first recording the workspace we're leaving so
# that pressing the workspace hotkey for the jumped-to workspace toggles back
# to where you were before auto-focus moved you.

source "$HOME/.config/hypr/scripts/notify-focus-lib.sh"

addr="$1"
[[ -z "$addr" ]] && exit 1

cur=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .activeWorkspace.id')
tgt=$(hyprctl clients -j | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')

# Window gone — nothing to focus.
[[ -z "$tgt" || "$tgt" == "null" ]] && exit 1

nf_record_prev "$cur" "$tgt"

hyprctl dispatch focuswindow "address:$addr"
