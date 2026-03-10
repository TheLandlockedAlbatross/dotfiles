#!/bin/bash
# Cycle odd/even workspace-monitor split across three states:
#   1) Odd workspaces on monitor A, even on B
#   2) Odd on B, even on A
#   3) Off (no workspace-monitor binding)
# Usage: workspace-split.sh [on|off|toggle]

# State file stores current mode: "normal", "flipped", or absent = off
STATE_FILE=/tmp/hypr-workspace-split

ACTION="${1:-toggle}"

get_monitors() {
  hyprctl monitors -j | jq -r '[.[] | select(.disabled == false)] | sort_by(.id) | .[].name'
}

monitor_count() {
  hyprctl monitors -j | jq '[.[] | select(.disabled == false)] | length'
}

apply_split() {
  local odd_mon="$1" even_mon="$2" mode="$3"

  for ws in 1 3 5 7 9; do
    hyprctl keyword workspace "$ws, monitor:$odd_mon" >/dev/null 2>&1
    hyprctl dispatch moveworkspacetomonitor "$ws $odd_mon" >/dev/null 2>&1
  done
  for ws in 2 4 6 8 10; do
    hyprctl keyword workspace "$ws, monitor:$even_mon" >/dev/null 2>&1
    hyprctl dispatch moveworkspacetomonitor "$ws $even_mon" >/dev/null 2>&1
  done

  echo "$mode" > "$STATE_FILE"
  swayosd-client --custom-icon video-display --custom-message "Workspace split: odd → $odd_mon, even → $even_mon"
}

clear_split() {
  for ws in $(seq 1 10); do
    hyprctl keyword workspace "$ws, monitor:" >/dev/null 2>&1
  done

  rm -f "$STATE_FILE"
  swayosd-client --custom-icon video-display --custom-message "Workspace split off"
}

require_two_monitors() {
  if (( $(monitor_count) < 2 )); then
    swayosd-client --custom-icon dialog-information --custom-message "Workspace split needs two displays"
    exit 0
  fi
}

read_monitors() {
  local monitors
  monitors=$(get_monitors)
  MON_A=$(echo "$monitors" | head -1)
  MON_B=$(echo "$monitors" | sed -n '2p')
}

case "$ACTION" in
  on)
    require_two_monitors
    read_monitors
    apply_split "$MON_A" "$MON_B" "normal"
    ;;
  off)
    clear_split
    ;;
  toggle)
    require_two_monitors
    read_monitors
    current=$(cat "$STATE_FILE" 2>/dev/null)
    case "$current" in
      normal)  apply_split "$MON_B" "$MON_A" "flipped" ;;
      flipped) clear_split ;;
      *)       apply_split "$MON_A" "$MON_B" "normal" ;;
    esac
    ;;
esac
