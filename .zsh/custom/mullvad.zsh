alias m='mullvad '
m_shuffle_func() {
    local dep
    for dep in mullvad jq curl; do
        if ! command -v "$dep" &> /dev/null; then
            echo "m_shuffle: required command '$dep' not installed"
            return 1
        fi
    done
    local cache_dir="${HOME}/.cache/mullvad"
    local state_file="${cache_dir}/relay_position"
    local relays_cache="${cache_dir}/relays.json"
    local coords_cache="${cache_dir}/city_coords.json"
    local home_loc_file="${cache_dir}/home_location"

    _m_shuffle_help() {
        cat <<'EOF'
Usage: m_shuffle [COMMAND]

Cycle through Mullvad relays sorted by distance from home location.

Commands:
  (none)      Go to next relay (further from home)
  <N>         Jump to relay #N (must be valid index)
  reset       Go back to relay #1 (closest to home)
  reset-home  Re-detect home location (requires VPN disconnected)
  status      Show current position and home location
  help        Show this help message

Cache files stored in: ~/.cache/mullvad/
EOF
    }

    _m_shuffle_urlencode() {
        jq -sRr @uri <<< "$1" | sed 's/%0A$//'
    }

    _m_shuffle_detect_home() {
        if mullvad status 2>/dev/null | grep -q "Connected"; then
            echo "Error: Mullvad is connected. Disconnect first for accurate home location detection."
            echo "Run: mullvad disconnect && m_shuffle"
            return 1
        fi
        echo "Detecting home location..."
        local geo=$(curl -s --max-time 10 "http://ip-api.com/json/" 2>/dev/null)
        local lat=$(echo "$geo" | jq -r '.lat // empty')
        local lon=$(echo "$geo" | jq -r '.lon // empty')
        local city=$(echo "$geo" | jq -r '.city // empty')
        local country=$(echo "$geo" | jq -r '.country // empty')
        if [[ -n "$lat" && -n "$lon" ]]; then
            echo "${lat},${lon}" > "$home_loc_file"
            [[ -n "$city" ]] && echo "${city}, ${country}" > "${home_loc_file}.city"
            echo "Home location set to: $city, $country ($lat, $lon)"
            return 0
        else
            echo "Could not detect location. Set manually: echo 'LAT,LON' > $home_loc_file"
            return 1
        fi
    }

    _m_shuffle_get_relay_info() {
        local hostname="$1"
        [[ -z "$hostname" || ! -f "$relays_cache" ]] && return 1
        jq -r --arg h "$hostname" '.[] | select(.hostname == $h) | "\(.city_name)|\(.country_name)"' "$relays_cache" 2>/dev/null
    }

    _m_shuffle_get_relay_coords() {
        local hostname="$1"
        [[ -z "$hostname" || ! -f "$relays_cache" || ! -f "$coords_cache" ]] && return 1
        local city_code=$(jq -r --arg h "$hostname" '.[] | select(.hostname == $h) | .city_code' "$relays_cache" 2>/dev/null)
        [[ -z "$city_code" ]] && return 1
        jq -r --arg c "$city_code" '.[$c] | "\(.lat),\(.lon)"' "$coords_cache" 2>/dev/null
    }

    _m_shuffle_build_sorted_list() {
        local home_lat="$1" home_lon="$2"
        jq -r --slurpfile coords "$coords_cache" '
            .[] | select(.active == true) |
            . as $r | $coords[0][.city_code] as $c |
            select($c != null) |
            "\(.hostname)|\($c.lat)|\($c.lon)"
        ' "$relays_cache" 2>/dev/null | awk -F'|' -v hlat="$home_lat" -v hlon="$home_lon" '
            function haversine(lat1, lon1, lat2, lon2) {
                pi = 3.14159265359; r = 6371
                dlat = (lat2 - lat1) * pi / 180
                dlon = (lon2 - lon1) * pi / 180
                lat1r = lat1 * pi / 180
                lat2r = lat2 * pi / 180
                a = sin(dlat/2)^2 + cos(lat1r) * cos(lat2r) * sin(dlon/2)^2
                return r * 2 * atan2(sqrt(a), sqrt(1-a))
            }
            { printf "%.0f|%s\n", haversine(hlat, hlon, $2, $3), $1 }
        ' | sort -t'|' -k1 -n | cut -d'|' -f2
    }

    mkdir -p "$cache_dir"

    # Parse command
    local cmd="${1:-next}"
    case "$cmd" in
        help|-h|--help)
            _m_shuffle_help
            return 0
            ;;
        status)
            echo "=== m_shuffle status ==="
            echo ""

            # Home location
            if [[ -f "$home_loc_file" ]]; then
                local home_coords=$(cat "$home_loc_file")
                local home_city="unknown"
                [[ -f "${home_loc_file}.city" ]] && home_city=$(cat "${home_loc_file}.city")
                echo "Home: $home_city ($home_coords)"
            else
                echo "Home: not set (run 'm_shuffle' to detect)"
                return 0
            fi

            # Need caches for relay info
            if [[ ! -f "$relays_cache" || ! -f "$coords_cache" ]]; then
                echo ""
                echo "Relay cache not built yet. Run 'm_shuffle' first."
                return 0
            fi

            local home_lat=$(cut -d',' -f1 < "$home_loc_file")
            local home_lon=$(cut -d',' -f2 < "$home_loc_file")

            # Build sorted list
            local sorted_relays=$(_m_shuffle_build_sorted_list "$home_lat" "$home_lon")
            local total=$(echo "$sorted_relays" | wc -l)

            # Current VPN status
            echo ""
            local mullvad_status=$(mullvad status 2>/dev/null)
            if echo "$mullvad_status" | grep -q "Connected"; then
                local current_relay=$(echo "$mullvad_status" | grep -oE '[a-z]{2}-[a-z]{3}-wg-[0-9]+' | head -1)
                if [[ -n "$current_relay" ]]; then
                    local cur_info=$(_m_shuffle_get_relay_info "$current_relay")
                    local cur_coords=$(_m_shuffle_get_relay_coords "$current_relay")
                    local cur_city=$(echo "$cur_info" | cut -d'|' -f1)
                    local cur_country=$(echo "$cur_info" | cut -d'|' -f2)
                    echo "Connected: $current_relay"
                    echo "           $cur_city, $cur_country ($cur_coords)"

                    # Find position in sorted list
                    local cur_pos=$(echo "$sorted_relays" | grep -n "^${current_relay}$" | cut -d: -f1)
                    if [[ -n "$cur_pos" ]]; then
                        echo "           Position: $cur_pos/$total"
                    fi
                else
                    echo "Connected: (could not parse relay)"
                fi
            else
                echo "VPN: Disconnected"
            fi

            # List position from state file
            local state_pos=0
            [[ -f "$state_file" ]] && state_pos=$(cat "$state_file")

            echo ""
            echo "List position: $state_pos/$total"

            # Previous relay
            echo ""
            if [[ $state_pos -le 1 ]]; then
                echo "Previous: (none - at start of list)"
            else
                local prev_pos=$((state_pos - 1))
                local prev_relay=$(echo "$sorted_relays" | sed -n "${prev_pos}p")
                local prev_info=$(_m_shuffle_get_relay_info "$prev_relay")
                local prev_coords=$(_m_shuffle_get_relay_coords "$prev_relay")
                local prev_city=$(echo "$prev_info" | cut -d'|' -f1)
                local prev_country=$(echo "$prev_info" | cut -d'|' -f2)
                echo "Previous:  #$prev_pos $prev_relay"
                echo "           $prev_city, $prev_country ($prev_coords)"
            fi

            # Next relay
            if [[ $state_pos -ge $total ]]; then
                echo "Next:      (none - at end of list)"
            else
                local next_pos=$((state_pos + 1))
                local next_relay=$(echo "$sorted_relays" | sed -n "${next_pos}p")
                local next_info=$(_m_shuffle_get_relay_info "$next_relay")
                local next_coords=$(_m_shuffle_get_relay_coords "$next_relay")
                local next_city=$(echo "$next_info" | cut -d'|' -f1)
                local next_country=$(echo "$next_info" | cut -d'|' -f2)
                echo "Next:      #$next_pos $next_relay"
                echo "           $next_city, $next_country ($next_coords)"
            fi

            return 0
            ;;
        reset-home)
            rm -f "$home_loc_file" "${home_loc_file}.city"
            echo "Home location cleared."
            _m_shuffle_detect_home || return 1
            ;;
        reset|next)
            ;;
        [0-9]*)
            # Numeric argument - will validate after building relay list
            ;;
        *)
            echo "Unknown command: $cmd"
            echo ""
            _m_shuffle_help
            return 1
            ;;
    esac

    # Ensure home location exists
    if [[ ! -f "$home_loc_file" ]]; then
        _m_shuffle_detect_home || return 1
    fi

    local home_lat=$(cut -d',' -f1 < "$home_loc_file")
    local home_lon=$(cut -d',' -f2 < "$home_loc_file")

    # Fetch relay list (cache for 24h)
    if [[ ! -f "$relays_cache" ]] || [[ -n $(find "$relays_cache" -mmin +1440 2>/dev/null) ]]; then
        echo "Updating relay list..."
        curl -s "https://api.mullvad.net/www/relays/wireguard/" > "$relays_cache"
    fi

    # Build city coordinates cache using Nominatim (rate-limited, cached permanently)
    [[ -f "$coords_cache" ]] || echo '{}' > "$coords_cache"

    local cities=$(jq -r '.[] | "\(.city_code)|\(.city_name)|\(.country_name)"' "$relays_cache" | sort -u)

    while IFS='|' read -r code city country; do
        if ! jq -e --arg c "$code" '.[$c]' "$coords_cache" >/dev/null 2>&1; then
            echo "Geocoding: $city, $country..."
            local query=$(_m_shuffle_urlencode "$city, $country")
            local result=$(curl -s --max-time 10 \
                "https://nominatim.openstreetmap.org/search?q=${query}&format=json&limit=1" \
                -H "User-Agent: mullvad-zsh-script" 2>/dev/null)
            local clat=$(echo "$result" | jq -r '.[0].lat // empty' 2>/dev/null)
            local clon=$(echo "$result" | jq -r '.[0].lon // empty' 2>/dev/null)
            if [[ -n "$clat" && -n "$clon" ]]; then
                local tmp=$(mktemp)
                jq --arg c "$code" --arg lat "$clat" --arg lon "$clon" \
                    '. + {($c): {"lat": ($lat|tonumber), "lon": ($lon|tonumber)}}' "$coords_cache" > "$tmp" 2>/dev/null
                mv "$tmp" "$coords_cache"
            else
                echo "  Warning: Could not geocode $city, $country"
            fi
            sleep 1  # Rate limit for Nominatim
        fi
    done <<< "$cities"

    # Build sorted relay list by distance
    local sorted_relays=$(jq -r --slurpfile coords "$coords_cache" '
        .[] | select(.active == true) |
        . as $r | $coords[0][.city_code] as $c |
        select($c != null) |
        "\(.hostname)|\($c.lat)|\($c.lon)"
    ' "$relays_cache" 2>/dev/null | awk -F'|' -v hlat="$home_lat" -v hlon="$home_lon" '
        function haversine(lat1, lon1, lat2, lon2) {
            pi = 3.14159265359; r = 6371
            dlat = (lat2 - lat1) * pi / 180
            dlon = (lon2 - lon1) * pi / 180
            lat1r = lat1 * pi / 180
            lat2r = lat2 * pi / 180
            a = sin(dlat/2)^2 + cos(lat1r) * cos(lat2r) * sin(dlon/2)^2
            return r * 2 * atan2(sqrt(a), sqrt(1-a))
        }
        { printf "%.0f|%s\n", haversine(hlat, hlon, $2, $3), $1 }
    ' | sort -t'|' -k1 -n | cut -d'|' -f2)

    local total=$(echo "$sorted_relays" | wc -l)

    if [[ $total -eq 0 ]]; then
        echo "No relays available"
        return 1
    fi

    # Handle numeric index jump
    if [[ "$cmd" =~ ^[0-9]+$ ]]; then
        if [[ $cmd -lt 1 || $cmd -gt $total ]]; then
            echo "Error: Index $cmd out of range (valid: 1-$total)"
            return 1
        fi
        echo "$cmd" > "$state_file"
        local relay=$(echo "$sorted_relays" | sed -n "${cmd}p")
        echo "Jumping to relay $cmd/$total: $relay"
        mullvad relay set location "$relay" > /dev/null
        mullvad connect --wait
        mullvad status
        return 0
    fi

    # Get current position
    local current_pos=0
    [[ -f "$state_file" ]] && current_pos=$(cat "$state_file")

    # Calculate next position
    local next_pos
    if [[ "$cmd" == "reset" ]]; then
        next_pos=1
    else
        next_pos=$((current_pos + 1))
        [[ $next_pos -gt $total ]] && next_pos=1
    fi

    echo "$next_pos" > "$state_file"

    local relay=$(echo "$sorted_relays" | sed -n "${next_pos}p")

    echo "Relay $next_pos/$total: $relay"
    mullvad relay set location "$relay" > /dev/null
    mullvad connect --wait
    mullvad status
}
alias m_shuffle='m_shuffle_func '

m_exclude_ff_func() {
    local dep
    for dep in mullvad-exclude firefox rsync; do
        if ! command -v "$dep" &> /dev/null; then
            echo "m_exclude_ff: required command '$dep' not installed"
            return 1
        fi
    done
    local src_profile="$1"
    if [[ -z "$src_profile" ]]; then
        echo "Usage: m_exclude_ff <firefox-profile-name> [url...]"
        return 1
    fi
    shift
    local urls=("$@")

    local ff_dir="$HOME/.mozilla/firefox"
    local exc_profile="${src_profile}_mullvad-exclude"

    # Resolve source profile directory from profiles.ini
    local src_dir=$(awk -F= -v name="$src_profile" '
        /^\[Profile/ { found=0 }
        $1=="Name" && $2==name { found=1 }
        found && $1=="Path" { print $2; exit }
    ' "$ff_dir/profiles.ini")

    if [[ -z "$src_dir" ]]; then
        echo "Error: profile '$src_profile' not found in profiles.ini"
        return 1
    fi

    # Create mullvad-exclude profile if it doesn't exist
    local exc_dir=$(awk -F= -v name="$exc_profile" '
        /^\[Profile/ { found=0 }
        $1=="Name" && $2==name { found=1 }
        found && $1=="Path" { print $2; exit }
    ' "$ff_dir/profiles.ini")

    if [[ -z "$exc_dir" ]]; then
        echo "Creating profile '$exc_profile'..."
        firefox --CreateProfile "$exc_profile" 2>/dev/null
        exc_dir=$(awk -F= -v name="$exc_profile" '
            /^\[Profile/ { found=0 }
            $1=="Name" && $2==name { found=1 }
            found && $1=="Path" { print $2; exit }
        ' "$ff_dir/profiles.ini")
        if [[ -z "$exc_dir" ]]; then
            echo "Error: failed to create profile '$exc_profile'"
            return 1
        fi
    fi

    local src_path="$ff_dir/$src_dir"
    local exc_path="$ff_dir/$exc_dir"

    # Sync: checksum-based skip, overwrite everything else
    echo "Syncing '$src_profile' -> '$exc_profile'..."
    echo ""

    local rsync_out
    rsync_out=$(rsync -rc --itemize-changes "$src_path/" "$exc_path/" 2>&1)

    if [[ -n "$rsync_out" ]]; then
        local changed=$(echo "$rsync_out" | wc -l)
        echo "$changed file(s) updated:"
        echo "$rsync_out" | head -20
        [[ $changed -gt 20 ]] && echo "  ... and $((changed - 20)) more"
    else
        echo "Already in sync, no files changed."
    fi

    echo ""

    # Launch with mullvad-exclude
    echo "Launching '$exc_profile' outside Mullvad tunnel..."
    mullvad-exclude firefox -P "$exc_profile" --no-remote "${urls[@]}" &>/dev/null &
    disown
}
alias m_exclude_ff='m_exclude_ff_func '
alias m_yt='m_exclude_ff_func default-release youtube.com'
alias m_ff_novpn='mullvad-exclude firefox -P default-release-NO_VPN --no-remote'
