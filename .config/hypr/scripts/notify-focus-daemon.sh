#!/bin/bash

# Daemon that monitors D-Bus notifications and auto-focuses tagged windows.
# Managed by notify-focus-tag.sh — not meant to be run manually.

STATE_FILE="/tmp/hypr-notify-focus-tags"
PID_FILE="/tmp/hypr-notify-focus-daemon.pid"

# Exit if already running
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  exit 0
fi

echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"; exit' EXIT INT TERM

walk_pid_to_match() {
  local check_pid=$1
  shift
  local tagged_pids=("$@")
  while [[ $check_pid -gt 1 ]]; do
    for tp in "${tagged_pids[@]}"; do
      [[ $check_pid -eq $tp ]] && echo "$tp" && return 0
    done
    check_pid=$(awk '/^PPid:/{print $2}' "/proc/$check_pid/status" 2>/dev/null) || return 1
  done
  return 1
}

stdbuf -oL busctl --user --json=short monitor --match "interface=org.freedesktop.Notifications,member=Notify" 2>/dev/null | while IFS= read -r line; do
  # Skip non-JSON lines (busctl prints a header)
  [[ "$line" != "{"* ]] && continue

  # Ignore our own notifications
  app_name=$(echo "$line" | jq -r '.payload.data[0] // empty')
  [[ "$app_name" == "notify-focus" ]] && continue

  # Extract sender PID from payload hint
  notif_pid=$(echo "$line" | jq -r '.payload.data[6]["sender-pid"].data // empty')

  # Fallback: resolve D-Bus sender to PID
  if [[ -z "$notif_pid" ]]; then
    sender=$(echo "$line" | jq -r '.sender // empty')
    [[ -n "$sender" ]] && notif_pid=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetConnectionUnixProcessID s "$sender" 2>/dev/null | awk '{print $2}')
  fi

  [[ -z "$notif_pid" ]] && continue

  # Read tags
  [[ ! -f "$STATE_FILE" ]] && continue
  tags=$(cat "$STATE_FILE")
  [[ "$tags" == "[]" ]] && continue

  # Get tagged PIDs and addresses
  mapfile -t tagged_pids < <(echo "$tags" | jq -r '.[].pid')
  mapfile -t tagged_addrs < <(echo "$tags" | jq -r '.[].address')

  # Walk PID tree to find a match
  matched_pid=$(walk_pid_to_match "$notif_pid" "${tagged_pids[@]}") || continue

  # Find the tagged window address for this PID
  for i in "${!tagged_pids[@]}"; do
    if [[ "${tagged_pids[$i]}" == "$matched_pid" ]]; then
      target_addr="${tagged_addrs[$i]}"
      break
    fi
  done

  [[ -z "$target_addr" ]] && continue

  # Verify window still exists and get its workspace
  window=$(hyprctl clients -j | jq --arg addr "$target_addr" '.[] | select(.address == $addr)')
  if [[ -z "$window" ]]; then
    # Window closed — remove stale tag
    jq --arg addr "$target_addr" '[.[] | select(.address != $addr)]' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    continue
  fi

  # Focus the window
  hyprctl dispatch focuswindow "address:$target_addr"
done
