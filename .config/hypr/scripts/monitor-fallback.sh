#!/bin/bash
# Listen for monitor events.
# - If no active displays remain after removal, enable eDP-1.
# - Auto-disable workspace split when dropping to one monitor.
# - Auto-re-enable workspace split when a second monitor appears.

SPLIT_STATE=/tmp/hypr-workspace-split
SPLIT_SCRIPT="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/scripts/workspace-split.sh"

socat -U - "UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" | while read -r line; do
  if [[ "$line" == monitorremoved* ]]; then
    active=$(hyprctl monitors -j | jq '[.[] | select(.disabled == false)] | length')
    if (( active == 0 )); then
      hyprctl keyword monitor "eDP-1, preferred, auto, 2"
      swayosd-client --custom-icon video-display --custom-message "eDP-1 enabled (no other displays)"
    elif (( active < 2 )) && [[ -f $SPLIT_STATE ]]; then
      "$SPLIT_SCRIPT" off
    fi
  elif [[ "$line" == monitoradded* ]]; then
    sleep 1
    active=$(hyprctl monitors -j | jq '[.[] | select(.disabled == false)] | length')
    if (( active >= 2 )) && [[ ! -f $SPLIT_STATE ]]; then
      "$SPLIT_SCRIPT" on
    fi
  fi
done
