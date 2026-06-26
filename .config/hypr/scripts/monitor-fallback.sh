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
# Retries up to 10s to handle cold-boot DRM initialization delays.
resolve_primary() {
  if [[ -n "$PRIMARY_DISPLAY" ]]; then
    echo "$PRIMARY_DISPLAY"
    return
  fi
  local attempts=20
  for (( i=1; i<=attempts; i++ )); do
    for f in /sys/class/drm/card*-eDP-*/status; do
      [[ -f "$f" ]] || continue
      local dir
      dir=$(basename "$(dirname "$f")")
      echo "${dir#card*-}"
      return
    done
    sleep 0.5
  done
}

# Check if any external (non-primary) display is currently active in Hyprland.
# Uses hyprctl (not raw DRM status) so that connectors explicitly disabled in
# monitors.conf — or phantom connectors that always report "connected" at DRM
# level — don't count as an active external display.
any_external_connected() {
  local primary="$1"
  local count
  count=$(hyprctl monitors -j 2>/dev/null \
    | jq --arg p "$primary" '[.[] | select(.name != $p)] | length')
  [[ -n "$count" && "$count" -gt 0 ]]
}

check_monitors() {
  local primary
  primary=$(resolve_primary)
  if [[ -z "$primary" ]]; then
    logger -t monitor-fallback "WARNING: could not detect primary display"
    return 1
  fi

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
# Retries up to 3 times to handle post-wake DRM/display settling.
if [[ "$1" == "check" ]]; then
  for attempt in 1 2 3; do
    check_monitors && exit 0
    sleep 1
  done
  exit 1
fi

# Daemon mode: check on startup, then listen for monitor events.
# resolve_primary retries internally, so no fixed sleep needed.
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
