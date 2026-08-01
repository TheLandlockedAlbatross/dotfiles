#!/bin/bash
# Waybar custom/network module: replicate vanilla network widget + VPN overlay
# Outputs JSON: {"text": "...", "tooltip": "...", "class": "..."}

source "$HOME/.config/hypr/scripts/vpn-lib.sh"

BW_FILE="/tmp/waybar-net-bw"

VPN_UP_COLOR="#88bb88"
VPN_DOWN_COLOR="#bb5555"

fmt_bw() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        awk "BEGIN{printf \"%.1f GB/s\", $bytes/1073741824}"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN{printf \"%.1f MB/s\", $bytes/1048576}"
    elif (( bytes >= 1024 )); then
        awk "BEGIN{printf \"%.1f kB/s\", $bytes/1024}"
    else
        echo "${bytes} B/s"
    fi
}

calc_bw() {
    local iface=$1
    rx_now=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)
    tx_now=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)
    if [[ -f "$BW_FILE" ]]; then
        read -r rx_prev tx_prev < "$BW_FILE"
        rx_delta=$(( rx_now - rx_prev ))
        tx_delta=$(( tx_now - tx_prev ))
        (( rx_delta < 0 )) && rx_delta=0
        (( tx_delta < 0 )) && tx_delta=0
    else
        rx_delta=0
        tx_delta=0
    fi
    echo "$rx_now $tx_now" > "$BW_FILE"
    DOWN=$(fmt_bw "$rx_delta")
    UP=$(fmt_bw "$tx_delta")
}

# --- Find default interface ---
default_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')

# --- Determine physical interface (route may point at the VPN tunnel) ---
if vpn_iface_pattern "$default_iface"; then
    phys_iface=""
    # A real NIC has a /device symlink; tunnels, bridges and veths do not.
    for d in /sys/class/net/*/device; do
        iface=$(basename "$(dirname "$d")")
        [[ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)" == "1" ]] || continue
        phys_iface="$iface"
        break
    done
    bw_iface="${phys_iface:-$default_iface}"
else
    phys_iface="$default_iface"
    bw_iface="$default_iface"
fi

# --- Detect connection type ---
if [[ -z "$phys_iface" ]]; then
    ICON="󰤮"
    TOOLTIP="Disconnected"
    CLASS=""
elif [[ -d "/sys/class/net/$phys_iface/wireless" ]]; then
    # Wifi — get ESSID and freq from iw dev link
    IW_LINK=$(iw dev "$phys_iface" link 2>/dev/null)
    ESSID=$(echo "$IW_LINK" | awk '/SSID:/{$1=""; print substr($0,2)}')
    FREQ=$(echo "$IW_LINK" | awk '/freq:/{printf "%.1f", $2/1000}')

    # Signal strength from iw (dBm → percentage, -90=0% to -30=100%)
    dbm=$(echo "$IW_LINK" | awk '/signal:/{print $2+0}')
    if [[ -n "$dbm" ]]; then
        signal=$(( (dbm + 90) * 100 / 60 ))
        (( signal > 100 )) && signal=100
        (( signal < 0 )) && signal=0
    else
        signal=0
    fi

    if (( signal >= 80 )); then ICON="󰤨"
    elif (( signal >= 60 )); then ICON="󰤥"
    elif (( signal >= 40 )); then ICON="󰤢"
    elif (( signal >= 20 )); then ICON="󰤟"
    else ICON="󰤯"
    fi

    calc_bw "$bw_iface"
    TOOLTIP="$ESSID ($FREQ GHz)\\n⇣$DOWN  ⇡$UP"
    CLASS=""
else
    # Ethernet
    ICON="󰀂"
    calc_bw "$bw_iface"
    TOOLTIP="⇣$DOWN  ⇡$UP"
    CLASS=""
fi

# --- VPN overlay (skip if incognito) ---
# Recolours the link icon in place; the glyph itself never changes.
if [[ ! -f "$VPN_INCOGNITO_FILE" ]] && vpn_available && [[ -n "$phys_iface" ]]; then
    VPN_STATUS=$(vpn_status 1)
    if vpn_is_connected "$VPN_STATUS"; then
        RELAY=$(vpn_relay "$VPN_STATUS")
        COUNTRY_NAME=$(vpn_country_name "$(vpn_relay_country "$RELAY")")
        ICON="<span color='$VPN_UP_COLOR'>$ICON</span>"
        TOOLTIP="$TOOLTIP\\n  $COUNTRY_NAME ($RELAY)"
        CLASS="vpn-connected"
    else
        ICON="<span color='$VPN_DOWN_COLOR'>$ICON</span>"
        TOOLTIP="$TOOLTIP\\n$VPN_NAME not connected!"
        CLASS="vpn-disconnected"
    fi
fi

# --- Output JSON ---
if [[ -n "$CLASS" ]]; then
    printf '{"text": "%s", "tooltip": "%s", "class": "%s"}\n' "$ICON" "$TOOLTIP" "$CLASS"
else
    printf '{"text": "%s", "tooltip": "%s"}\n' "$ICON" "$TOOLTIP"
fi
