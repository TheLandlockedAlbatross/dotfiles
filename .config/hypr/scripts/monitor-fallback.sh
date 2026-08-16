#!/bin/bash
# Ensure the primary display is enabled when all external displays disconnect,
# and keep the workspace->monitor mapping in step with what is plugged in.
# - Checks on startup, after wake, and on monitor hotplug events.
#
# Can be run standalone for a one-shot check (e.g. from hypridle after_sleep_cmd):
#   monitor-fallback.sh check

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/scripts"
WS_MAP="$CONF_DIR/workspace-map.sh"

# Load optional override for PRIMARY_DISPLAY.
# shellcheck source=monitor-fallback.conf
[[ -f "$CONF_DIR/monitor-fallback.conf" ]] && source "$CONF_DIR/monitor-fallback.conf"

# Resolve primary display: use configured value, or auto-detect first eDP connector.
# Retries up to 10s to handle cold-boot DRM initialization delays.
#
# Memoized, including a negative result: a desktop has no eDP at all, so every
# call would otherwise pay the full 10s of retries for an answer that can never
# change. The result lands in $PRIMARY rather than on stdout, because a caller
# using $(resolve_primary) would run it in a subshell and throw the cache away.
PRIMARY=""
PRIMARY_RESOLVED=false
resolve_primary() {
  $PRIMARY_RESOLVED && return
  PRIMARY_RESOLVED=true
  if [[ -n "$PRIMARY_DISPLAY" ]]; then
    PRIMARY="$PRIMARY_DISPLAY"
    return
  fi
  local attempts=20
  for (( i=1; i<=attempts; i++ )); do
    for f in /sys/class/drm/card*-eDP-*/status; do
      [[ -f "$f" ]] || continue
      local dir
      dir=$(basename "$(dirname "$f")")
      PRIMARY="${dir#card*-}"
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
  resolve_primary
  primary="$PRIMARY"
  if [[ -z "$primary" ]]; then
    logger -t monitor-fallback "WARNING: could not detect primary display"
    return 1
  fi

  if ! any_external_connected "$primary"; then
    hyprctl keyword monitor "$primary, preferred, auto, 2"
    swayosd-client --custom-icon video-display --custom-message "$primary enabled (no other displays)"
  fi
}

# Re-resolve which display hosts each decade. Hyprland dumps the workspaces of
# a departing display onto whichever monitor it connected first, which has
# nothing to do with the layout, and it leaves the workspace rules pointing at
# a connector that is no longer there. workspace-map.sh fixes both, and takes
# its own lock, so a burst of events from a multi-head unplug serializes rather
# than racing.
remap_workspaces() {
  [[ -x "$WS_MAP" ]] || return 0
  "$WS_MAP" apply
}

# One-shot mode: run a single check and exit (used by hypridle after_sleep_cmd).
# Retries up to 3 times to handle post-wake DRM/display settling.
if [[ "$1" == "check" ]]; then
  rc=1
  for attempt in 1 2 3; do
    if check_monitors; then rc=0; break; fi
    sleep 1
  done
  # Waking can bring displays back or leave them behind, so remap either way.
  remap_workspaces
  exit "$rc"
fi

# Daemon mode: check on startup, then listen for monitor events.
# resolve_primary retries internally, so no fixed sleep needed.
check_monitors

while true; do
  socat -U - "UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" | while read -r line; do
    # Remap first: it is what the user sees, and check_monitors can spend up to
    # 10s hunting for an eDP panel that a desktop does not have.
    if [[ "$line" == monitorremoved* ]]; then
      sleep 0.5
      remap_workspaces
      check_monitors
    elif [[ "$line" == monitoradded* ]]; then
      # Longer settle: Hyprland walks its own reconnect path first, moving the
      # workspaces it stamped on unplug back to the returning display.
      sleep 1
      remap_workspaces
      check_monitors
    fi
  done
  sleep 2  # wait before reconnecting if socket drops
done
