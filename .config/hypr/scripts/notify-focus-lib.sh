#!/bin/bash

# Shared state and daemon helpers for the notify-focus auto-focus feature.
# Sourced by notify-focus-tag.sh (toggle), notify-focus-list.sh (popup),
# and notify-focus-menu.sh (omarchy dropdown).

NF_STATE_FILE="/tmp/hypr-notify-focus-tags"
NF_DAEMON_SCRIPT="$HOME/.config/hypr/scripts/notify-focus-daemon.sh"
NF_DAEMON_PID_FILE="/tmp/hypr-notify-focus-daemon.pid"
# Same file workspace-switch.sh uses, so the workspace hotkey toggles back to
# wherever auto-focus pulled you away from.
NF_PREV_FILE="/tmp/hypr-workspace-prev"

nf_init() { [[ ! -f "$NF_STATE_FILE" ]] && echo '[]' > "$NF_STATE_FILE"; }

# nf_record_prev <from_workspace> <to_workspace> — only records a "previous"
# when the jump actually crossed workspaces.
nf_record_prev() {
  [[ -n "$1" && "$1" != "null" && "$1" != "$2" ]] && echo "$1" > "$NF_PREV_FILE"
  return 0
}

# Tier 2: a persistent, clickable badge instead of a switch. One pending alert
# per window, guarded by a lock file. Shared by the daemon and the Claude Code
# notification hook, so the lock also dedupes across the two trigger paths.
nf_raise_alert() {
  local addr="$1" ws lock
  lock="/tmp/hypr-notify-focus-alert-${addr//x/}"
  [[ -e "$lock" ]] && return 0
  ws=$(hyprctl clients -j | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')
  [[ -z "$ws" ]] && return 0
  # setsid: the badge waits (possibly forever) for a click, so it must not die
  # with whichever short-lived script raised it.
  setsid bash -c '
    touch "$1"
    # Compact badge: the summary is just the workspace number. The address goes
    # in the body purely to keep same-workspace alerts from grouping into one —
    # the mako criteria hides the body via format, so only the number shows.
    action=$(notify-send -a notify-focus -c notify-focus-alert -t 0 \
      -A default="Go to workspace" "$2" "$3")
    [[ "$action" == "default" ]] && "$HOME/.config/hypr/scripts/notify-focus-goto.sh" "$3"
    rm -f "$1"
  ' _ "$lock" "$ws" "$addr" &
  return 0
}

nf_is_tagged() {
  jq -e --arg addr "$1" '.[] | select(.address == $addr)' "$NF_STATE_FILE" > /dev/null 2>&1
}

# Echo the tier (1 or 2) of a tagged window, or nothing if untagged.
nf_tier() {
  jq -r --arg addr "$1" '.[] | select(.address == $addr) | (.tier // 1)' "$NF_STATE_FILE" 2>/dev/null
}

# nf_tag <address> <pid> <class> <title> [tier]  — tier defaults to 1.
# Re-tagging an already-tagged window updates its tier.
nf_tag() {
  local addr="$1" pid="$2" class="$3" title="$4" tier="${5:-1}" tmp
  tmp=$(mktemp)
  jq --arg addr "$addr" --argjson pid "$pid" --arg class "$class" --arg title "$title" --argjson tier "$tier" \
    '[.[] | select(.address != $addr)] + [{"address": $addr, "pid": $pid, "class": $class, "title": $title, "tier": $tier}]' \
    "$NF_STATE_FILE" > "$tmp" && mv "$tmp" "$NF_STATE_FILE"
  nf_start_daemon
}

nf_untag() {
  local tmp
  tmp=$(mktemp)
  jq --arg addr "$1" '[.[] | select(.address != $addr)]' "$NF_STATE_FILE" > "$tmp" && mv "$tmp" "$NF_STATE_FILE"
  nf_stop_daemon_if_empty
}

# Drop tags whose windows have closed.
nf_prune() {
  local clients tmp
  clients=$(hyprctl clients -j)
  tmp=$(mktemp)
  jq --argjson clients "$clients" \
    '[.[] | select(.address as $a | $clients | any(.address == $a))]' \
    "$NF_STATE_FILE" > "$tmp" && mv "$tmp" "$NF_STATE_FILE"
  nf_stop_daemon_if_empty
}

nf_start_daemon() {
  if [[ ! -f "$NF_DAEMON_PID_FILE" ]] || ! kill -0 "$(cat "$NF_DAEMON_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    # Detached, so it outlives the keybind that started it. The daemon's own
    # flock makes a redundant start harmless.
    setsid "$NF_DAEMON_SCRIPT" >/dev/null 2>&1 &
    disown 2>/dev/null
  fi
}

nf_stop_daemon_if_empty() {
  local remaining
  remaining=$(jq length "$NF_STATE_FILE" 2>/dev/null)
  if [[ "$remaining" -eq 0 ]] && [[ -f "$NF_DAEMON_PID_FILE" ]]; then
    kill "$(cat "$NF_DAEMON_PID_FILE")" 2>/dev/null
    rm -f "$NF_DAEMON_PID_FILE"
  fi
}
