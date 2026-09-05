#!/bin/bash
# Connect/disconnect toggle - the ONLY binding that changes VPN state, in both
# backends. Connected (or tunnel up) -> disconnect; otherwise -> connect to the
# currently selected relay. Cycle/status keys never touch state.

source "$HOME/.config/hypr/scripts/vpn-lib.sh"

SWAYOSD="$HOME/.config/hypr/scripts/swayosd-focused.sh"
CONNECT_TIMEOUT=20

err() {
    "$SWAYOSD" --custom-icon network-error --custom-message "$1"
    exit 1
}

[[ "$VPN_BACKEND" == none ]] && err "$VPN_NAME: nothing installed"

STATUS=$(vpn_status)
if vpn_is_connected "$STATUS"; then
    "$SWAYOSD" --custom-icon security-high --custom-message "$VPN_NAME Disconnecting..."
    vpn_disconnect || err "$VPN_NAME: disconnect failed"
    while ! vpn_is_disconnected; do sleep 0.5; done
    "$SWAYOSD" --custom-icon network-error --custom-message "$VPN_NAME Disconnected"
else
    "$SWAYOSD" --custom-icon security-medium --custom-message "$VPN_NAME Connecting..."
    vpn_connect || err "$VPN_NAME: connect failed"
    elapsed=0
    while ! vpn_is_connected; do
        sleep 0.5
        elapsed=$((elapsed + 1))
        [[ $elapsed -ge $((CONNECT_TIMEOUT * 2)) ]] && err "$VPN_NAME: connection timed out after ${CONNECT_TIMEOUT}s"
    done
    "$SWAYOSD" --custom-icon security-high --custom-message "$VPN_NAME Connected ($(vpn_relay))"
fi
