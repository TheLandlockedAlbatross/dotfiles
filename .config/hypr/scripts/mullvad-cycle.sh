#!/bin/bash
# Mullvad relay cycling script
# Usage: mullvad-cycle.sh [next|prev]
# Dynamically builds relay list for current country, sorted by distance from home.

DIRECTION="${1:-next}"
SWAYOSD="$HOME/.config/hypr/scripts/swayosd-focused.sh"
LOC_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/mullvad/home.loc"
CONNECT_TIMEOUT=15

err() {
    "$SWAYOSD" --custom-icon network-error --custom-message "$1"
    exit 1
}

# --- Preflight: check mullvad daemon is running ---
if ! mullvad status &>/dev/null; then
    err "Mullvad daemon not running"
fi

# --- Preflight: check network connectivity ---
if ! ping -c1 -W2 1.1.1.1 &>/dev/null; then
    err "Mullvad: No internet connection"
fi

# --- Home location setup ---
# home.loc contains a single line: lat,lon,country
# If missing, prompt the user to generate it.
if [[ ! -f "$LOC_FILE" ]]; then
    # Launch a floating terminal to prompt for location setup
    setsid uwsm-app -- xdg-terminal-exec --app-id=org.omarchy.terminal --title="Mullvad: Home Location" -e bash -c '
        LOC_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/mullvad/home.loc"
        SWAYOSD="$HOME/.config/hypr/scripts/swayosd-focused.sh"

        echo ""
        gum style --bold --foreground 212 "Mullvad: Home Location Setup"
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
                "$SWAYOSD" --custom-icon network-error --custom-message "Mullvad: No internet — cannot detect location"
                sleep 2
                exit 1
            fi
            LOC=$(echo "$INFO" | jq -r ".loc // empty")
            COUNTRY=$(echo "$INFO" | jq -r ".country // empty" | tr "[:upper:]" "[:lower:]")
            if [[ -z "$LOC" || "$LOC" != *","* || -z "$COUNTRY" ]]; then
                gum style --foreground 196 "Failed to parse location from response."
                "$SWAYOSD" --custom-icon network-error --custom-message "Mullvad: Failed to detect location"
                sleep 2
                exit 1
            fi
            mkdir -p "$(dirname "$LOC_FILE")"
            echo "$LOC,$COUNTRY" > "$LOC_FILE"
            gum style --foreground 120 "Location saved: $LOC ($COUNTRY)"
            "$SWAYOSD" --custom-icon security-high --custom-message "Home location saved ($COUNTRY)"
            sleep 1
        else
            "$SWAYOSD" --custom-icon network-error --custom-message "Mullvad: Home location required"
        fi
    ' &
    exit 0
fi

HOME_LAT=$(cut -d, -f1 < "$LOC_FILE")
HOME_LON=$(cut -d, -f2 < "$LOC_FILE")
HOME_COUNTRY=$(cut -d, -f3 < "$LOC_FILE")

# --- Get current status ---
STATUS=$(mullvad status)
IS_CONNECTED=$(echo "$STATUS" | head -1 | grep -q Connected && echo yes || echo no)

if [[ "$IS_CONNECTED" == "no" ]]; then
    COUNTRY="$HOME_COUNTRY"
else
    CURRENT_RELAY=$(echo "$STATUS" | grep Relay | tr -s " " | cut -d" " -f3)
    COUNTRY=$(echo "$CURRENT_RELAY" | cut -d- -f1)
fi

# Parse cities in this country from mullvad relay list, sort by haversine distance from home
# Output format: "COUNTRY CITY" per line, nearest first
mapfile -t RELAYS < <(
    mullvad relay list | awk -v country="($COUNTRY)" -v hlat="$HOME_LAT" -v hlon="$HOME_LON" '
    BEGIN { pi = 3.14159265358979; found = 0 }
    # Match the country line
    /^\S/ {
        if (found) exit
        if (index($0, country)) { found = 1; code = country; gsub(/[()]/, "", code) }
        next
    }
    # Match city lines with coordinates (only while in our country)
    found && /^\t[A-Z]/ {
        # Format: \tCityName (code) @ lat°N, lon°W
        match($0, /\(([a-z]+)\)/, ca)
        match($0, /@ ([0-9.-]+)°N, ([0-9.-]+)°W/, co)
        if (ca[1] && co[1] != "") {
            city = ca[1]
            lat = co[1] + 0
            lon = co[2] + 0
            # Haversine
            dlat = (lat - hlat) * pi / 180
            dlon = (lon - hlon) * pi / 180
            a = sin(dlat/2)^2 + cos(hlat*pi/180)*cos(lat*pi/180)*sin(dlon/2)^2
            d = 2 * atan2(sqrt(a), sqrt(1-a)) * 6371
            printf "%s %s %.1f\n", code, city, d
        }
    }
    ' | sort -t' ' -k3 -n | awk '{print $1, $2}'
)

COUNT=${#RELAYS[@]}
if [[ $COUNT -eq 0 ]]; then
    err "No Mullvad relays found for country: $COUNTRY"
fi

# --- Wait for connection with timeout ---
wait_for_connected() {
    local elapsed=0
    while ! mullvad status | head -1 | grep -q Connected; do
        sleep 0.5
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $((CONNECT_TIMEOUT * 2)) ]]; then
            err "Mullvad: Connection timed out after ${CONNECT_TIMEOUT}s"
        fi
    done
}

# --- Disconnected: connect to nearest relay ---
if [[ "$IS_CONNECTED" == "no" ]]; then
    LOC="${RELAYS[0]}"
    "$SWAYOSD" --custom-icon network-error --custom-message "Mullvad Connecting..."
    if ! mullvad relay set location $LOC; then
        err "Mullvad: Failed to set relay $LOC"
    fi
    if ! mullvad connect; then
        err "Mullvad: Connect failed — check internet connection"
    fi
    wait_for_connected
    S=$(mullvad status)
    R=$(echo "$S" | grep Relay | tr -s " " | cut -d" " -f3)
    "$SWAYOSD" --custom-icon security-high --custom-message "Mullvad Connected ($R) [1/$COUNT]"
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
    "$SWAYOSD" --custom-icon security-high --custom-message "Mullvad Switching Relays (${RELAYS[$CURRENT_IDX]} -> $LOC) ..."
else
    "$SWAYOSD" --custom-icon security-high --custom-message "Mullvad Switching Relays ($LOC <- ${RELAYS[$CURRENT_IDX]}) ..."
fi
if ! mullvad relay set location $LOC; then
    err "Mullvad: Failed to set relay $LOC"
fi
if ! mullvad reconnect; then
    err "Mullvad: Reconnect failed — check internet connection"
fi
wait_for_connected
S=$(mullvad status)
R=$(echo "$S" | grep Relay | tr -s " " | cut -d" " -f3)
IDX_DISPLAY=$((NEXT_IDX + 1))
"$SWAYOSD" --custom-icon security-high --custom-message "Mullvad Connected ($R) [$IDX_DISPLAY/$COUNT]"
