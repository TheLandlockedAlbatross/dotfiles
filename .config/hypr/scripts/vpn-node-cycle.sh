#!/bin/bash
# VPN node cycling script
# Usage: vpn-node-cycle.sh [next|prev]
# Cycles through individual server nodes within the current city.

source "$HOME/.config/hypr/scripts/vpn-lib.sh"

DIRECTION="${1:-next}"
SWAYOSD="$HOME/.config/hypr/scripts/swayosd-focused.sh"
CONNECT_TIMEOUT=15

err() {
    "$SWAYOSD" --custom-icon network-error --custom-message "$1"
    exit 1
}

# --- Must be connected to cycle nodes ---
STATUS=$(vpn_status)
if ! vpn_is_connected "$STATUS"; then
    err "$VPN_NAME: Must be connected to cycle nodes"
fi

CURRENT_RELAY=$(vpn_relay "$STATUS")
# Extract country-city prefix (e.g. us-bos from us-bos-wg-101)
COUNTRY=$(vpn_relay_country "$CURRENT_RELAY")
CITY=$(vpn_relay_city "$CURRENT_RELAY")

# --- Get all nodes in this city ---
mapfile -t NODES < <(vpn_nodes_in_city "$COUNTRY" "$CITY")

COUNT=${#NODES[@]}
if [[ $COUNT -le 1 ]]; then
    err "$VPN_NAME: Only $COUNT node(s) in $COUNTRY-$CITY — nothing to cycle"
fi

# --- Find current node index ---
CURRENT_IDX=-1
for i in "${!NODES[@]}"; do
    if [[ "${NODES[$i]}" == "$CURRENT_RELAY" ]]; then
        CURRENT_IDX=$i
        break
    fi
done
if [[ $CURRENT_IDX -eq -1 ]]; then
    CURRENT_IDX=0
fi

# --- Cycle ---
if [[ "$DIRECTION" == "next" ]]; then
    NEXT_IDX=$(( (CURRENT_IDX + 1) % COUNT ))
else
    NEXT_IDX=$(( (CURRENT_IDX - 1 + COUNT) % COUNT ))
fi

NEXT_NODE="${NODES[$NEXT_IDX]}"
IDX_DISPLAY=$((NEXT_IDX + 1))

"$SWAYOSD" --custom-icon security-high --custom-message "$VPN_NAME Node: $CURRENT_RELAY → $NEXT_NODE ..."

if ! vpn_set_location "$NEXT_NODE"; then
    err "$VPN_NAME: Failed to set node $NEXT_NODE"
fi
if ! vpn_reconnect; then
    err "$VPN_NAME: Reconnect failed"
fi

# --- Wait for connection ---
elapsed=0
while ! vpn_is_connected; do
    sleep 0.5
    elapsed=$((elapsed + 1))
    if [[ $elapsed -ge $((CONNECT_TIMEOUT * 2)) ]]; then
        err "$VPN_NAME: Connection timed out after ${CONNECT_TIMEOUT}s"
    fi
done

R=$(vpn_relay)
"$SWAYOSD" --custom-icon security-high --custom-message "$VPN_NAME Node: $R [$IDX_DISPLAY/$COUNT]"
