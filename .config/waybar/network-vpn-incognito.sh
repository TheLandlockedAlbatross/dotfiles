#!/bin/bash
# Toggle VPN overlay visibility in the waybar network widget

INCOGNITO_FILE="/tmp/waybar-incognito"
SWAYOSD="$HOME/.config/hypr/scripts/swayosd-focused.sh"

if [[ -f "$INCOGNITO_FILE" ]]; then
    rm "$INCOGNITO_FILE"
    "$SWAYOSD" --custom-icon security-high --custom-message "VPN overlay: visible"
else
    touch "$INCOGNITO_FILE"
    "$SWAYOSD" --custom-icon security-low --custom-message "VPN overlay: hidden"
fi
