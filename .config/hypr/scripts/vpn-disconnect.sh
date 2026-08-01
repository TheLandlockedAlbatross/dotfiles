#!/bin/bash
# Disconnect the VPN and wait for the tunnel to drop.

source "$HOME/.config/hypr/scripts/vpn-lib.sh"

SWAYOSD="$HOME/.config/hypr/scripts/swayosd-focused.sh"

"$SWAYOSD" --custom-icon security-high --custom-message "$VPN_NAME Disconnecting..."
vpn_disconnect || exit 1
while ! vpn_is_disconnected; do sleep 0.5; done
"$SWAYOSD" --custom-icon network-error --custom-message "$VPN_NAME Disconnected"
