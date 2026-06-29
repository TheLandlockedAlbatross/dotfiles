# Per-app Mullvad tunnelling via vopono (network-namespace based).
# Only the launched app goes through Mullvad; the rest of the system
# (including Tailscale) is untouched. See ~/.config/vopono/.
#
# Quick use:
#   vp                 list recent apps + default server
#   vp <N>             launch recent app #N through Mullvad
#   vp <cmd...>        launch a command through Mullvad (and remember it)
#   vp 1               (seeded) firefox -P default-release --no-remote
#   vp 2               (seeded) qbittorrent

vp_func() {
    emulate -L zsh
    local cache_dir="${HOME}/.cache/vopono"
    local apps_file="${cache_dir}/recent_apps"
    local server_file="${cache_dir}/server"
    local log_file="${cache_dir}/last.log"
    local wg_dir="${HOME}/.config/vopono/mv/wireguard"
    local provider="mullvad"
    # Absolute path: vopono self-elevates via `sudo -E <argv[0]>`, and root's
    # secure_path excludes ~/.cargo/bin — a bare name fails with "command not found".
    local vopono_bin
    vopono_bin=$(command -v vopono 2>/dev/null)
    [[ -x "$vopono_bin" ]] || vopono_bin="${HOME}/.cargo/bin/vopono"
    # Shared with m_shuffle so the proximity ordering is identical.
    local mull_cache="${HOME}/.cache/mullvad"
    local relays_cache="${cache_dir}/relays.json"
    local coords_cache="${mull_cache}/city_coords.json"
    local home_loc="${mull_cache}/home_location"
    local pos_file="${cache_dir}/server_pos"
    mkdir -p "$cache_dir"

    local default_server
    default_server=$(cat "$server_file" 2>/dev/null)
    [[ -z "$default_server" ]] && default_server="netherlands"

    _vp_help() {
        cat <<EOF
Usage: vp [OPTIONS] [N | COMMAND...]

Launch a single app through Mullvad (vopono network namespace). Nothing else
on the system is affected (Tailscale included).

Launching:
  vp                       List recent apps and the default server
  vp <N>                   Launch recent app #N (see the numbered list)
  vp <command...>          Launch command through Mullvad, remember it
  vp -s <server> <N|cmd>   Use a specific server just for this launch

Server (ordered by distance from home, same list as m_shuffle):
  vp server                Show default server
  vp server ls             List servers closest-first (numbered, * = current)
  vp server <N>            Set default to the Nth-closest server
  vp server next           Advance to the next server further out (cycles)
  vp server reset          Set default to the closest server
  vp server <name>         Set default to a literal name (e.g. sweden, nl-ams)

Recent-app list:
  vp ls                    Show numbered recent-app list
  vp rm <N>                Remove entry #N
  vp clear                 Empty the list

Other:
  vp ps                    Show active vopono namespaces
  vp log                   Show output of the last launch (for debugging)
  vp help                  This help

Server names match by prefix against ~/.config/vopono/mv/wireguard/*.conf
(e.g. "netherlands", "nl-ams", or a full "netherlands-nl-ams-wg-001").
EOF
    }

    _vp_list() {
        if [[ ! -s "$apps_file" ]]; then
            echo "  (no recent apps yet)"
            return
        fi
        local i=1 line
        while IFS= read -r line; do
            printf "  %2d  %s\n" "$i" "$line"
            (( i++ ))
        done < "$apps_file"
    }

    # Move a command to the top of the MRU list (dedup, cap 20)
    _vp_record() {
        local cmd="$1" tmp
        tmp=$(mktemp)
        {
            print -r -- "$cmd"
            [[ -f "$apps_file" ]] && grep -vxF -- "$cmd" "$apps_file"
        } | head -n 20 > "$tmp"
        mv "$tmp" "$apps_file"
    }

    _vp_launch() {
        local server="$1"; shift
        local cmd="$*"
        if [[ -z "$cmd" ]]; then echo "vp: nothing to launch"; return 1; fi
        # Cache sudo credentials up front so the backgrounded vopono (which
        # self-elevates) doesn't silently block on a password prompt.
        echo "Acquiring sudo (for namespace setup)..."
        sudo -v || { echo "vp: sudo required"; return 1; }
        echo "→ Mullvad [$server]: $cmd"
        ( "$vopono_bin" exec --provider "$provider" --protocol wireguard \
              --server "$server" "$cmd" >"$log_file" 2>&1 ) &!
        echo "  launched (pid $!).  'vp log' for output, 'vp ps' for namespaces."
    }

    # Fetch Mullvad relay list (cache 24h) — needed for the proximity sort.
    _vp_ensure_relays() {
        if [[ ! -s "$relays_cache" || -n $(find "$relays_cache" -mmin +1440 2>/dev/null) ]]; then
            echo "Updating relay list..." >&2
            curl -s "https://api.mullvad.net/www/relays/wireguard/" > "$relays_cache"
        fi
        [[ -s "$relays_cache" ]]
    }

    # Emit servers sorted by distance from home (closest first):
    #   "<dist>\t<conf>\t<city, country>"
    # Reuses m_shuffle's home_location + city_coords.json for identical ordering.
    _vp_sorted() {
        _vp_ensure_relays || { echo "vp: could not fetch relay list" >&2; return 1; }
        if [[ ! -s "$coords_cache" || ! -s "$home_loc" ]]; then
            echo "vp: missing home/coords cache — run 'm_shuffle' once to build it" >&2
            return 1
        fi
        local hlat hlon b mapf
        hlat=$(cut -d, -f1 < "$home_loc"); hlon=$(cut -d, -f2 < "$home_loc")
        # suffix (conf name after first dash) -> conf basename
        mapf=$(mktemp)
        for b in "$wg_dir"/*.conf(N); do b=${b:t:r}; print -- "${b#*-} $b"; done > "$mapf"
        jq -r --slurpfile coords "$coords_cache" '
            .[] | select(.active==true) | . as $r | $coords[0][.city_code] as $c |
            select($c != null) |
            "\(.hostname)|\($c.lat)|\($c.lon)|\(.city_name)|\(.country_name)"
        ' "$relays_cache" 2>/dev/null | awk -F'|' -v hlat="$hlat" -v hlon="$hlon" -v mapf="$mapf" '
            function haversine(lat1, lon1, lat2, lon2,   pi,r,dlat,dlon,a) {
                pi=3.14159265359; r=6371
                dlat=(lat2-lat1)*pi/180; dlon=(lon2-lon1)*pi/180
                a=sin(dlat/2)^2 + cos(lat1*pi/180)*cos(lat2*pi/180)*sin(dlon/2)^2
                return r*2*atan2(sqrt(a),sqrt(1-a))
            }
            BEGIN { while((getline line < mapf)>0){ split(line,p," "); m[p[1]]=p[2] } }
            { sfx=$1; sub(/-wg-/,"-",sfx); gsub(/-/,"",sfx);
              if((conf=m[sfx])=="") next;
              printf "%.0f\t%s\t%s, %s\n", haversine(hlat,hlon,$2,$3), conf, $4, $5 }
        ' | sort -n -k1,1
        rm -f "$mapf"
    }

    # ---- subcommands -------------------------------------------------------
    case "$1" in
        help|-h|--help)
            _vp_help; return 0 ;;
        ""|ls|list)
            echo "Default server: $default_server"
            echo "Recent apps (launch with 'vp <N>'):"
            _vp_list
            [[ "$1" == "" ]] && { echo ""; echo "'vp help' for full usage."; }
            return 0 ;;
        server)
            case "$2" in
                ""|show)
                    echo "Default server: $default_server" ;;
                ls|list)
                    local i=1 dist conf loc mark
                    _vp_sorted | while IFS=$'\t' read -r dist conf loc; do
                        mark="  "; [[ "$conf" == "$default_server" ]] && mark="* "
                        printf "%s%3d  %-22s %s (%s km)\n" "$mark" "$i" "$conf" "$loc" "$dist"
                        (( i++ ))
                    done ;;
                next|shuffle)
                    local sorted total pos conf loc
                    sorted=$(_vp_sorted) || return 1
                    total=$(print -r -- "$sorted" | wc -l)
                    pos=$(cat "$pos_file" 2>/dev/null || echo 0)
                    (( pos++ )); (( pos > total )) && pos=1
                    conf=$(print -r -- "$sorted" | sed -n "${pos}p" | cut -f2)
                    loc=$(print -r -- "$sorted" | sed -n "${pos}p" | cut -f3)
                    print -r -- "$pos" > "$pos_file"
                    print -r -- "$conf" > "$server_file"
                    echo "Default server → $conf  (#$pos/$total: $loc)" ;;
                reset)
                    local sorted conf loc
                    sorted=$(_vp_sorted) || return 1
                    conf=$(print -r -- "$sorted" | sed -n 1p | cut -f2)
                    loc=$(print -r -- "$sorted" | sed -n 1p | cut -f3)
                    print -r -- 1 > "$pos_file"
                    print -r -- "$conf" > "$server_file"
                    echo "Default server → $conf  (#1, closest: $loc)" ;;
                <->)
                    local sorted total conf loc
                    sorted=$(_vp_sorted) || return 1
                    total=$(print -r -- "$sorted" | wc -l)
                    if (( $2 < 1 || $2 > total )); then
                        echo "vp: server index out of range (1-$total)"; return 1
                    fi
                    conf=$(print -r -- "$sorted" | sed -n "${2}p" | cut -f2)
                    loc=$(print -r -- "$sorted" | sed -n "${2}p" | cut -f3)
                    print -r -- "$2" > "$pos_file"
                    print -r -- "$conf" > "$server_file"
                    echo "Default server → $conf  (#$2: $loc)" ;;
                *)
                    print -r -- "$2" > "$server_file"
                    echo "Default server → $2" ;;
            esac
            return 0 ;;
        rm)
            if [[ ! "$2" =~ ^[0-9]+$ ]]; then echo "Usage: vp rm <N>"; return 1; fi
            if [[ ! -s "$apps_file" ]]; then echo "vp: no recent apps"; return 1; fi
            sed -i "${2}d" "$apps_file" && echo "Removed entry $2"
            return 0 ;;
        clear)
            : > "$apps_file"; echo "Recent apps cleared."; return 0 ;;
        log)
            if [[ -s "$log_file" ]]; then cat "$log_file"; else echo "(no log yet)"; fi
            return 0 ;;
        ps)
            "$vopono_bin" list namespaces 2>/dev/null || echo "(no active namespaces)"
            return 0 ;;
    esac

    # ---- launch path -------------------------------------------------------
    local server="$default_server"
    if [[ "$1" == "-s" || "$1" == "--server" ]]; then
        if [[ -z "$2" ]]; then echo "vp: -s needs a server name"; return 1; fi
        server="$2"; shift 2
    fi

    if [[ -z "$1" ]]; then _vp_help; return 1; fi

    local app
    if [[ "$1" =~ ^[0-9]+$ && $# -eq 1 ]]; then
        # Numeric => launch from MRU list
        app=$(sed -n "${1}p" "$apps_file" 2>/dev/null)
        if [[ -z "$app" ]]; then
            echo "vp: no recent app #$1"
            _vp_list
            return 1
        fi
    else
        app="$*"
        # Reject typos / non-commands so they never get launched or remembered.
        if ! command -v "${app%% *}" >/dev/null 2>&1; then
            echo "vp: '${app%% *}' is not a command (nothing launched)"
            return 1
        fi
    fi

    _vp_launch "$server" "$app"
    _vp_record "$app"
}
alias vp='vp_func '
