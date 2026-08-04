#!/bin/bash
# VPN relay cycling script
# Usage: vpn-cycle.sh [next|prev]
# Dynamically builds relay list for current country, sorted by distance from home.

source "$HOME/.config/hypr/scripts/vpn-lib.sh"

DIRECTION="${1:-next}"
SWAYOSD="$HOME/.config/hypr/scripts/swayosd-focused.sh"
LOC_FILE="$VPN_CACHE_DIR/home.loc"
CONNECT_TIMEOUT=15

err() {
    "$SWAYOSD" --custom-icon network-error --custom-message "$1"
    exit 1
}

# --- Preflight: check the VPN daemon is running ---
if ! vpn_daemon_up; then
    err "$VPN_NAME daemon not running"
fi

# --- Preflight: check network connectivity ---
if ! ping -c1 -W2 1.1.1.1 &>/dev/null; then
    err "$VPN_NAME: No internet connection"
fi

# --- Home location setup ---
# home.loc contains a single line: lat,lon,country
# If missing, prompt the user to generate it.
if [[ ! -f "$LOC_FILE" ]]; then
    # Launch a floating terminal to prompt for location setup
    setsid uwsm-app -- xdg-terminal-exec --app-id=org.omarchy.terminal --title="$VPN_NAME: Home Location" -e bash -c '
        source "$HOME/.config/hypr/scripts/vpn-lib.sh"
        LOC_FILE="$VPN_CACHE_DIR/home.loc"
        SWAYOSD="$HOME/.config/hypr/scripts/swayosd-focused.sh"

        echo ""
        gum style --bold --foreground 212 "$VPN_NAME: Home Location Setup"
        echo ""
        echo "No home location reference point found."
        echo "This will be used to sort VPN relays by distance from you."
        echo ""
        gum style --bold --foreground 214 "IMPORTANT:"
        echo ""
        echo "  • Make sure no VPNs, proxies, or other software that"
        echo "    might obscure your true geographic location are running"
        echo "    right now. Accurate geolocation is your responsibility."
        echo ""
        echo "  • The generated file (home.loc) contains your real"
        echo "    coordinates. Do not share it or commit it to version control."
        echo ""

        if gum confirm "Detect your location now?"; then
            echo ""
            gum spin --title "Detecting location..." -- sleep 0.5
            INFO=$(curl -sf --connect-timeout 5 "https://ipinfo.io/json")
            if [[ -z "$INFO" ]]; then
                gum style --foreground 196 "Failed to reach ipinfo.io. Check your internet connection."
                "$SWAYOSD" --custom-icon network-error --custom-message "$VPN_NAME: No internet — cannot detect location"
                sleep 2
                exit 1
            fi
            LOC=$(echo "$INFO" | jq -r ".loc // empty")
            COUNTRY=$(echo "$INFO" | jq -r ".country // empty" | tr "[:upper:]" "[:lower:]")
            if [[ -z "$LOC" || "$LOC" != *","* || -z "$COUNTRY" ]]; then
                gum style --foreground 196 "Failed to parse location from response."
                "$SWAYOSD" --custom-icon network-error --custom-message "$VPN_NAME: Failed to detect location"
                sleep 2
                exit 1
            fi
            mkdir -p "$(dirname "$LOC_FILE")"
            echo "$LOC,$COUNTRY" > "$LOC_FILE"
            gum style --foreground 120 "Location saved: $LOC ($COUNTRY)"
            "$SWAYOSD" --custom-icon security-high --custom-message "Home location saved ($COUNTRY)"
            sleep 1
        else
            "$SWAYOSD" --custom-icon network-error --custom-message "$VPN_NAME: Home location required"
        fi
    ' &
    exit 0
fi

HOME_LAT=$(cut -d, -f1 < "$LOC_FILE")
HOME_LON=$(cut -d, -f2 < "$LOC_FILE")
HOME_COUNTRY=$(cut -d, -f3 < "$LOC_FILE")

# --- Get current status ---
STATUS=$(vpn_status)
IS_CONNECTED=$(vpn_is_connected "$STATUS" && echo yes || echo no)

if [[ "$IS_CONNECTED" == "no" ]]; then
    COUNTRY="$HOME_COUNTRY"
else
    CURRENT_RELAY=$(vpn_relay "$STATUS")
    COUNTRY=$(vpn_relay_country "$CURRENT_RELAY")
fi

# Cities in this country, sorted by distance from home. "COUNTRY CITY" per line, nearest first
mapfile -t RELAYS < <(vpn_cities_by_distance "$COUNTRY" "$HOME_LAT" "$HOME_LON")

COUNT=${#RELAYS[@]}
if [[ $COUNT -eq 0 ]]; then
    err "No $VPN_NAME relays found for country: $COUNTRY"
fi

# --- Wait for connection with timeout ---
wait_for_connected() {
    local elapsed=0
    while ! vpn_is_connected; do
        sleep 0.5
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $((CONNECT_TIMEOUT * 2)) ]]; then
            err "$VPN_NAME: Connection timed out after ${CONNECT_TIMEOUT}s"
        fi
    done
}

# --- Disconnected: connect to nearest relay ---
if [[ "$IS_CONNECTED" == "no" ]]; then
    LOC="${RELAYS[0]}"
    "$SWAYOSD" --custom-icon network-error --custom-message "$VPN_NAME Connecting..."
    if ! vpn_set_location "$LOC"; then
        err "$VPN_NAME: Failed to set relay $LOC"
    fi
    if ! vpn_connect; then
        err "$VPN_NAME: Connect failed — check internet connection"
    fi
    wait_for_connected
    R=$(vpn_relay)
    "$SWAYOSD" --custom-icon security-high --custom-message "$VPN_NAME Connected ($R) [1/$COUNT]"
    exit 0
fi

# --- Find current city in sorted list ---
CURRENT_LOC=$(echo "$CURRENT_RELAY" | awk -F- '{print $1, $2}')
CURRENT_IDX=-1
for i in "${!RELAYS[@]}"; do
    if [[ "${RELAYS[$i]}" == "$CURRENT_LOC" ]]; then
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

LOC="${RELAYS[$NEXT_IDX]}"

if [[ "$DIRECTION" == "next" ]]; then
    "$SWAYOSD" --custom-icon security-high --custom-message "$VPN_NAME Switching Relays (${RELAYS[$CURRENT_IDX]} -> $LOC) ..."
else
    "$SWAYOSD" --custom-icon security-high --custom-message "$VPN_NAME Switching Relays ($LOC <- ${RELAYS[$CURRENT_IDX]}) ..."
fi
if ! vpn_set_location "$LOC"; then
    err "$VPN_NAME: Failed to set relay $LOC"
fi
if ! vpn_reconnect; then
    err "$VPN_NAME: Reconnect failed — check internet connection"
fi
wait_for_connected
R=$(vpn_relay)
IDX_DISPLAY=$((NEXT_IDX + 1))
"$SWAYOSD" --custom-icon security-high --custom-message "$VPN_NAME Connected ($R) [$IDX_DISPLAY/$COUNT]"
