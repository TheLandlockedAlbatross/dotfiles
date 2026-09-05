#!/bin/bash
# Show current VPN state as an OSD notification. Three states:
#   green   daemon VPN connected (whole machine tunnelled)
#   orange  daemon down/disconnected but the browser tunnel namespace is up
#   red     neither
# The middle state exists because the netns tunnel keeps working while the
# daemon reports Disconnected; without it this read "Disconnected" while the
# VPN browser was happily tunnelled.

source "$HOME/.config/hypr/scripts/vpn-lib.sh"

SWAYOSD="$HOME/.config/hypr/scripts/swayosd-focused.sh"

DAEMON_STATUS=""
[[ "$VPN_BACKEND" == daemon ]] && DAEMON_STATUS=$(vpn_status 1)

if [[ -n "$DAEMON_STATUS" ]] && vpn_is_connected "$DAEMON_STATUS"; then
    "$SWAYOSD" --custom-icon security-high --custom-message "$VPN_NAME Connected ($(vpn_relay "$DAEMON_STATUS"))"
elif vpn_tunnel_up; then
    N=$(vpn_tunnel_count)
    [[ $N -eq 1 ]] && T="1 Tunnel" || T="$N Tunnels"
    "$SWAYOSD" --custom-icon vpn-tunnel-active --custom-message "$VPN_NAME: $T Active ($(vpn_tunnel_relay))"
else
    "$SWAYOSD" --custom-icon network-error --custom-message "$VPN_NAME Disconnected"
fi
