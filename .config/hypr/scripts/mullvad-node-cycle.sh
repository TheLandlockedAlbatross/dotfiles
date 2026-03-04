#!/bin/bash
# Mullvad node cycling script
# Usage: mullvad-node-cycle.sh [next|prev]
# Cycles through individual WireGuard nodes within the current city.

DIRECTION="${1:-next}"
SWAYOSD="$HOME/.config/hypr/scripts/swayosd-focused.sh"
CONNECT_TIMEOUT=15

err() {
    "$SWAYOSD" --custom-icon network-error --custom-message "$1"
    exit 1
}

# --- Must be connected to cycle nodes ---
STATUS=$(mullvad status 2>/dev/null)
if ! echo "$STATUS" | head -1 | grep -q Connected; then
    err "Mullvad: Must be connected to cycle nodes"
fi

CURRENT_RELAY=$(echo "$STATUS" | grep Relay | tr -s " " | cut -d" " -f3)
# Extract country-city prefix (e.g. us-bos from us-bos-wg-101)
COUNTRY=$(echo "$CURRENT_RELAY" | cut -d- -f1)
CITY=$(echo "$CURRENT_RELAY" | cut -d- -f2)

# --- Get all nodes in this city ---
mapfile -t NODES < <(
    mullvad relay list | awk -v country="($COUNTRY)" -v city="($CITY)" '
    BEGIN { found_country = 0; found_city = 0 }
    /^\S/ {
        if (found_city) exit
        found_country = (index($0, country) > 0)
        next
    }
    found_country && /^\t[A-Z]/ {
        if (found_city) exit
        found_city = (index($0, city) > 0)
        next
    }
    found_city && /^\t\t/ {
        # Extract hostname (first field after tabs)
        gsub(/^\t+/, "")
        print $1
    }
    '
)

COUNT=${#NODES[@]}
if [[ $COUNT -le 1 ]]; then
    err "Mullvad: Only $COUNT node(s) in $COUNTRY-$CITY — nothing to cycle"
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

"$SWAYOSD" --custom-icon security-high --custom-message "Mullvad Node: $CURRENT_RELAY → $NEXT_NODE ..."

if ! mullvad relay set location "$NEXT_NODE"; then
    err "Mullvad: Failed to set node $NEXT_NODE"
fi
if ! mullvad reconnect; then
    err "Mullvad: Reconnect failed"
fi

# --- Wait for connection ---
elapsed=0
while ! mullvad status | head -1 | grep -q Connected; do
    sleep 0.5
    elapsed=$((elapsed + 1))
    if [[ $elapsed -ge $((CONNECT_TIMEOUT * 2)) ]]; then
        err "Mullvad: Connection timed out after ${CONNECT_TIMEOUT}s"
    fi
done

S=$(mullvad status)
R=$(echo "$S" | grep Relay | tr -s " " | cut -d" " -f3)
"$SWAYOSD" --custom-icon security-high --custom-message "Mullvad Node: $R [$IDX_DISPLAY/$COUNT]"
