#!/bin/bash
# VPN provider adapter.
#
# Every provider-specific detail lives in this file. Callers (waybar widget,
# cycle scripts, omarchy menu, keybinds) only use the vpn_* functions below.
# To switch providers, change VPN_CLI and reimplement the functions.
#
# Source it with:  source "$HOME/.config/hypr/scripts/vpn-lib.sh"

VPN_CLI="${VPN_CLI:-mullvad}"          # backend CLI binary
VPN_NAME="${VPN_NAME:-VPN}"            # label shown in notifications
VPN_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/vpn"
VPN_INCOGNITO_FILE="/tmp/waybar-incognito"

# Interfaces the backend brings up. Used to look past the tunnel when
# reporting on the underlying physical link.
vpn_iface_pattern() { [[ "$1" == wg* ]]; }

# --- Availability / state ------------------------------------------------

vpn_available()  { command -v "$VPN_CLI" &>/dev/null; }
vpn_daemon_up()  { "$VPN_CLI" status &>/dev/null; }

# Raw status text. Optional arg: timeout in seconds.
vpn_status() {
    if [[ -n "$1" ]]; then
        timeout "$1" "$VPN_CLI" status 2>/dev/null
    else
        "$VPN_CLI" status 2>/dev/null
    fi
}

# Accepts optional pre-fetched status text to avoid a second CLI call.
vpn_is_connected()    { { [[ -n "$1" ]] && echo "$1" || vpn_status; } | head -1 | grep -q Connected; }
vpn_is_disconnected() { { [[ -n "$1" ]] && echo "$1" || vpn_status; } | head -1 | grep -q Disconnected; }

# Current server identifier, e.g. us-bos-wg-001
vpn_relay() { { [[ -n "$1" ]] && echo "$1" || vpn_status; } | grep Relay | tr -s " " | cut -d" " -f3; }

vpn_relay_country() { cut -d- -f1 <<<"$1"; }
vpn_relay_city()    { cut -d- -f2 <<<"$1"; }

# --- Actions -------------------------------------------------------------

vpn_set_location() { "$VPN_CLI" relay set location $1; }   # unquoted: may be "us bos"
vpn_connect()      { "$VPN_CLI" connect; }
vpn_disconnect()   { "$VPN_CLI" disconnect; }
vpn_reconnect()    { "$VPN_CLI" reconnect; }

# --- Server catalogue ----------------------------------------------------

vpn_server_list() { "$VPN_CLI" relay list 2>/dev/null; }

# Country lines only, e.g. "USA (us)"
vpn_countries() { vpn_server_list | grep -E "^\S"; }

# Country display name for a country code
vpn_country_name() {
    vpn_countries | grep "($1)" | head -1 | sed 's/ *(.*//;s/^ *//'
}

# Cities in a country, nearest first. Args: country_code home_lat home_lon
# Output: "country city" per line
vpn_cities_by_distance() {
    vpn_server_list | awk -v country="($1)" -v hlat="$2" -v hlon="$3" '
    BEGIN { pi = 3.14159265358979; found = 0 }
    /^\S/ {
        if (found) exit
        if (index($0, country)) { found = 1; code = country; gsub(/[()]/, "", code) }
        next
    }
    found && /^\t[A-Z]/ {
        # Format: \tCityName (code) @ lat°N, lon°W
        match($0, /\(([a-z]+)\)/, ca)
        match($0, /@ ([0-9.-]+)°N, ([0-9.-]+)°W/, co)
        if (ca[1] && co[1] != "") {
            city = ca[1]
            lat = co[1] + 0
            lon = co[2] + 0
            dlat = (lat - hlat) * pi / 180
            dlon = (lon - hlon) * pi / 180
            a = sin(dlat/2)^2 + cos(hlat*pi/180)*cos(lat*pi/180)*sin(dlon/2)^2
            d = 2 * atan2(sqrt(a), sqrt(1-a)) * 6371
            printf "%s %s %.1f\n", code, city, d
        }
    }
    ' | sort -t' ' -k3 -n | awk '{print $1, $2}'
}

# Individual server hostnames within a city. Args: country_code city_code
vpn_nodes_in_city() {
    vpn_server_list | awk -v country="($1)" -v city="($2)" '
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
        gsub(/^\t+/, "")
        print $1
    }
    '
}
