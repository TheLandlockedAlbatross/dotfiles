#!/bin/bash
# Show current VPN connection state as an OSD notification.

source "$HOME/.config/hypr/scripts/vpn-lib.sh"

SWAYOSD="$HOME/.config/hypr/scripts/swayosd-focused.sh"

STATUS=$(vpn_status)
if vpn_is_connected "$STATUS"; then
    "$SWAYOSD" --custom-icon security-high --custom-message "$VPN_NAME Connected ($(vpn_relay "$STATUS"))"
else
    "$SWAYOSD" --custom-icon network-error --custom-message "$VPN_NAME Disconnected"
fi
