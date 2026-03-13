#!/bin/bash
# Ensure the primary display is enabled when all external displays disconnect.
# - Checks on startup, after wake, and on monitor hot-unplug events.
# - Auto-toggles workspace split based on active display count.
#
# Can be run standalone for a one-shot check (e.g. from hypridle after_sleep_cmd):
#   monitor-fallback.sh check

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/scripts"
SPLIT_STATE=/tmp/hypr-workspace-split
SPLIT_SCRIPT="$CONF_DIR/workspace-split.sh"

# Load optional override for PRIMARY_DISPLAY.
# shellcheck source=monitor-fallback.conf
[[ -f "$CONF_DIR/monitor-fallback.conf" ]] && source "$CONF_DIR/monitor-fallback.conf"

# Resolve primary display: use configured value, or auto-detect first eDP connector.
resolve_primary() {
  if [[ -n "$PRIMARY_DISPLAY" ]]; then
    echo "$PRIMARY_DISPLAY"
    return
  fi
  for f in /sys/class/drm/card*-eDP-*/status; do
    [[ -f "$f" ]] || continue
    local dir
    dir=$(basename "$(dirname "$f")")
    echo "${dir#card*-}"
    return
  done
}

# Check if any external (non-primary) display is physically connected.
any_external_connected() {
  local primary="$1"
  for f in /sys/class/drm/card*/status; do
    [[ -f "$f" ]] || continue
    local dir
    dir=$(basename "$(dirname "$f")")
    local name="${dir#card*-}"
    [[ "$name" == "$primary" || "$name" == Writeback-* ]] && continue
    [[ "$(<"$f")" == "connected" ]] && return 0
  done
  return 1
}

check_monitors() {
  local primary
  primary=$(resolve_primary)
  [[ -z "$primary" ]] && return

  if ! any_external_connected "$primary"; then
    hyprctl keyword monitor "$primary, preferred, auto, 2"
    swayosd-client --custom-icon video-display --custom-message "$primary enabled (no other displays)"
    [[ -f "$SPLIT_STATE" ]] && "$SPLIT_SCRIPT" off
  else
    local active
    active=$(hyprctl monitors -j | jq '[.[] | select(.disabled == false)] | length')
    if (( active < 2 )) && [[ -f "$SPLIT_STATE" ]]; then
      "$SPLIT_SCRIPT" off
    elif (( active >= 2 )) && [[ ! -f "$SPLIT_STATE" ]]; then
      "$SPLIT_SCRIPT" on
    fi
  fi
}

# One-shot mode: run a single check and exit (used by hypridle after_sleep_cmd).
if [[ "$1" == "check" ]]; then
  check_monitors
  exit
fi

# Daemon mode: check on startup, then listen for monitor events.
sleep 2
check_monitors

while true; do
  socat -U - "UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" | while read -r line; do
    if [[ "$line" == monitorremoved* ]]; then
      sleep 0.5
      check_monitors
    elif [[ "$line" == monitoradded* ]]; then
      sleep 1
      check_monitors
    fi
  done
  sleep 2  # wait before reconnecting if socket drops
done
