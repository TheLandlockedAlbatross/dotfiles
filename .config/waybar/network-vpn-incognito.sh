#!/bin/bash
# Toggle VPN overlay visibility in the waybar network widget

source "$HOME/.config/hypr/scripts/vpn-lib.sh"

SWAYOSD="$HOME/.config/hypr/scripts/swayosd-focused.sh"

if [[ -f "$VPN_INCOGNITO_FILE" ]]; then
    rm "$VPN_INCOGNITO_FILE"
    "$SWAYOSD" --custom-icon security-high --custom-message "VPN overlay: visible"
else
    touch "$VPN_INCOGNITO_FILE"
    "$SWAYOSD" --custom-icon security-low --custom-message "VPN overlay: hidden"
fi
