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

# --- Backend dispatch ------------------------------------------------------
#
# Two backends provide the vpn_* API:
#   daemon - the provider CLI above, talking to its system daemon (claudius, or
#            Hamlet if the daemon is deliberately started)
#   netns  - the namespace tunnel (vpn-tunnel/vpn-server-ctl) that carries the
#            SUPER ALT B browser; see ~/.local/share/vpn-tunnel/
# Detected once per source: a running daemon wins, otherwise the namespace
# tooling if installed. Callers keep using the same functions either way.
#
# Hot-path rule: waybar sources this file on every poll, so status/relay in the
# netns backend read /run/netns and world-readable config only - no sudo. Only
# the state-changing calls go through the passwordless vpn-server-ctl shim.

VPN_TUNNEL_NS="${VPN_TUNNEL_NS:-vpn}"
VPN_TUNNEL_CTL=/usr/local/bin/vpn-server-ctl
VPN_TUNNEL_ETC=/etc/vpn-tunnel

vpn_tunnel_installed() { [[ -x $VPN_TUNNEL_CTL ]]; }
vpn_tunnel_up() { ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$VPN_TUNNEL_NS"; }

# How many tunnel namespaces are live. Today that is 0 or 1, but the namespace
# design allows several (vpn, vpn2, ...), so report a count rather than assume.
# Excludes helper namespaces like vpn-pre and vpn-diag.
vpn_tunnel_count() {
    ip netns list 2>/dev/null | awk '{print $1}' | grep -Ec "^${VPN_TUNNEL_NS}[0-9]*$" || true
}

# Current tunnel relay, daemon-style (us-was-wg-001): provider prefix stripped
# so vpn_relay_country/_city keep parsing. Reads root's 644 config, never sudo.
vpn_tunnel_relay() {
    local prov cfg
    prov=$(sed -n 's/^VPN_PROVIDER=//p' "$VPN_TUNNEL_ETC/config" 2>/dev/null | tail -1)
    cfg=$(sed -n 's/^VPN_CONFIG=//p' "$VPN_TUNNEL_ETC/providers/${prov:-mullvad}.conf" 2>/dev/null \
          | tail -1 | tr -d "'\"")
    cfg=${cfg##*/}; cfg=${cfg%.conf}
    [[ -n $prov ]] && cfg=${cfg#"$prov"-}
    cfg=${cfg%-\*}     # a fresh install leaves a glob; show the city, not the '*'
    echo "${cfg:-unknown}"
}

# "Active" beats "running": a daemon that is merely running while the namespace
# tunnel carries traffic must not steal the keybinds, or cycling would say
# "Disconnected" while the tunnel hums along. Priority: whichever is actually
# up; then a running daemon; then installed tunnel tooling.
if [[ -z "${VPN_BACKEND:-}" ]]; then
    _daemon_status=""
    command -v "$VPN_CLI" &>/dev/null && _daemon_status=$(timeout 1 "$VPN_CLI" status 2>/dev/null)
    if [[ -n $_daemon_status ]] && head -1 <<<"$_daemon_status" | grep -q Connected; then
        VPN_BACKEND=daemon
    elif vpn_tunnel_installed && vpn_tunnel_up; then
        VPN_BACKEND=netns
    elif [[ -n $_daemon_status ]]; then
        VPN_BACKEND=daemon
    elif vpn_tunnel_installed; then
        VPN_BACKEND=netns
    else
        VPN_BACKEND=none
    fi
    unset _daemon_status
fi

if [[ "$VPN_BACKEND" == netns ]]; then
    vpn_available() { vpn_tunnel_installed; }
    vpn_daemon_up() { vpn_tunnel_installed; }

    # Same text shape the daemon CLI prints, so the parsers above need no
    # changes. The leading space before Relay matters: vpn_relay squeezes
    # spaces and takes field 3.
    vpn_status() {
        if vpn_tunnel_up; then
            printf 'Connected\n  Relay: %s\n' "$(vpn_tunnel_relay)"
        else
            echo "Disconnected"
        fi
    }

    vpn_connect()    { sudo -n "$VPN_TUNNEL_CTL" up   >/dev/null 2>&1; }
    vpn_disconnect() { sudo -n "$VPN_TUNNEL_CTL" down >/dev/null 2>&1; }
    # set_location already reconnects live (and auto-reverts on failure), so a
    # follow-up reconnect from the cycle scripts has nothing left to do.
    vpn_reconnect()  { return 0; }
    vpn_set_location() { sudo -n "$VPN_TUNNEL_CTL" server "${1// /-}" >/dev/null 2>&1; }

    # The relay catalogue in the daemon CLI's text format, synthesized from the
    # provider's public relay API and cached for a day. This is what lets
    # vpn_cities_by_distance / vpn_nodes_in_city run unmodified.
    vpn_server_list() {
        local cache="$VPN_CACHE_DIR/relays.cli"
        if [[ ! -s $cache || $(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) )) -gt 86400 ]]; then
            mkdir -p "$VPN_CACHE_DIR"
            # The app API is the one with per-city coordinates: .locations keyed
            # "cc-city", relays under .wireguard pointing at those keys.
            curl -fsS --max-time 20 https://api.mullvad.net/app/v1/relays 2>/dev/null \
              | jq -r '
                  .locations as $loc
                  | [.wireguard.relays[] | select(.active)]
                  | group_by(.location | split("-")[0])[]
                  | ($loc[.[0].location].country) as $cn
                  | (.[0].location | split("-")[0]) as $cc
                  | "\($cn) (\($cc))",
                    ( group_by(.location)[]
                      | ($loc[.[0].location]) as $l
                      | (.[0].location | split("-")[1]) as $ci
                      | "\t\($l.city) (\($ci)) @ \($l.latitude)°N, \($l.longitude)°W",
                        ( sort_by(.hostname)[] | "\t\t\(.hostname)" ) )' \
              > "$cache.tmp" 2>/dev/null \
              && mv "$cache.tmp" "$cache" || rm -f "$cache.tmp"
        fi
        cat "$cache" 2>/dev/null
    }
fi
