#!/bin/bash

# Toggle notify-focus tag on the currently focused window.
# Tagged windows will be auto-focused when they send a notification.

STATE_FILE="/tmp/hypr-notify-focus-tags"
DAEMON_SCRIPT="$HOME/.config/hypr/scripts/notify-focus-daemon.sh"
DAEMON_PID_FILE="/tmp/hypr-notify-focus-daemon.pid"

[[ ! -f "$STATE_FILE" ]] && echo '[]' > "$STATE_FILE"

window=$(hyprctl activewindow -j)
address=$(echo "$window" | jq -r '.address')
pid=$(echo "$window" | jq -r '.pid')
class=$(echo "$window" | jq -r '.class')
title=$(echo "$window" | jq -r '.title')

if [[ -z "$address" || "$address" == "null" ]]; then
  notify-send -a notify-focus "No focused window"
  exit 1
fi

tags=$(cat "$STATE_FILE")

if echo "$tags" | jq -e --arg addr "$address" '.[] | select(.address == $addr)' > /dev/null 2>&1; then
  # Untag
  echo "$tags" | jq --arg addr "$address" '[.[] | select(.address != $addr)]' > "$STATE_FILE"
  hyprctl notify 0 3000 0 "Untagged: $class — ${title:0:40}"

  # Stop daemon if no tags remain
  remaining=$(jq length "$STATE_FILE")
  if [[ "$remaining" -eq 0 ]] && [[ -f "$DAEMON_PID_FILE" ]]; then
    kill "$(cat "$DAEMON_PID_FILE")" 2>/dev/null
    rm -f "$DAEMON_PID_FILE"
  fi
else
  # Tag
  echo "$tags" | jq --arg addr "$address" --argjson pid "$pid" --arg class "$class" --arg title "$title" \
    '. + [{"address": $addr, "pid": $pid, "class": $class, "title": $title}]' > "$STATE_FILE"
  hyprctl notify 0 3000 0 "Tagged: $class — ${title:0:40}"

  # Start daemon if not running
  if [[ ! -f "$DAEMON_PID_FILE" ]] || ! kill -0 "$(cat "$DAEMON_PID_FILE")" 2>/dev/null; then
    "$DAEMON_SCRIPT" &
  fi
fi
