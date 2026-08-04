#!/bin/bash
# Wrapper around swayosd-client that targets only the focused monitor
MONITOR=$(hyprctl monitors -j | jq -r '.[] | select(.focused == true).name')
exec swayosd-client --monitor "$MONITOR" "$@"
