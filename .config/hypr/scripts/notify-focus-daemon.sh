#!/bin/bash

# Daemon that watches D-Bus notifications and auto-focuses tagged windows.
# Started and stopped by notify-focus-lib.sh — not meant to be run manually.

source "$HOME/.config/hypr/scripts/notify-focus-lib.sh"

LOCK_FILE="/tmp/hypr-notify-focus-daemon.lock"
GOTO="$HOME/.config/hypr/scripts/notify-focus-goto.sh"

# Run with NF_DEBUG=1 to trace how each notification was resolved.
nf_log() { [[ -n "$NF_DEBUG" ]] && printf '%s %s\n' "$(date +%H:%M:%S.%3N)" "$*" >&2; return 0; }

# Single-instance guard via flock: the lock auto-releases when this process
# dies (even on SIGKILL), so it can't be defeated by a stale PID file.
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

echo $$ > "$NF_DAEMON_PID_FILE"

# Clear tier-2 alert locks left behind by a previous daemon that was killed
# while an alert was still pending. A surviving lock silently suppresses every
# future alert for that window. Safe to do here: flock guarantees we are the
# only daemon, so no live alert can own one of these.
rm -f /tmp/hypr-notify-focus-alert-* 2>/dev/null
BUSCTL_PID=""
# On exit, drop the PID file and kill the busctl monitor child so it can't
# linger as an orphan (the bug that used to stack dozens of monitors).
trap 'rm -f "$NF_DAEMON_PID_FILE"; [[ -n "$BUSCTL_PID" ]] && kill "$BUSCTL_PID" 2>/dev/null; exit' EXIT INT TERM

# --- sender resolution -------------------------------------------------------

# Fill the global `ancestry` array with a pid and all of its forebears, reading
# /proc directly with no forks. Speed is the entire point here: a notify-send
# style sender exits within a few milliseconds of its call landing on the bus,
# so anything that waits on a subprocess first finds /proc/<pid> already gone
# and the match fails every single time.
# /proc/<pid>/stat is a single line, so one builtin read gets the parent —
# /proc/<pid>/status would mean looping over ~50 lines per hop, and every
# microsecond spent here is a microsecond the sender has to exit.
snapshot_ancestry() {
  local pid=$1 stat rest ppid
  ancestry=()
  while [[ "$pid" =~ ^[0-9]+$ ]] && ((pid > 1)); do
    ancestry+=("$pid")
    stat=""
    # `read` is a builtin, so this whole hop costs no fork at all.
    read -r -d '' stat 2>/dev/null < "/proc/$pid/stat"
    [[ -z "$stat" ]] && break
    # Skip the parenthesised comm field, which may itself contain spaces.
    rest="${stat##*") "}"
    ppid="${rest#* }"
    pid="${ppid%% *}"
  done
  ((${#ancestry[@]} > 0))
}

# --- actions -----------------------------------------------------------------

# Is this address one of the windows owned by the process that notified?
is_owner_window() {
  local a
  for a in "${owner_addrs[@]}"; do [[ "$a" == "$1" ]] && return 0; done
  return 1
}

# Undo our jump, but only if the user has not moved on in the meantime —
# yanking focus back out from under someone who deliberately clicked elsewhere
# is worse than the stray jump we are trying to correct.
restore_focus() {
  local now
  now=$(hyprctl activewindow -j | jq -r '.address // empty')
  [[ -n "$prev_addr" && "$now" == "$1" ]] && hyprctl dispatch focuswindow "address:$prev_addr" >/dev/null
  return 0
}

act_on() {
  local addr="$1" tier="$2"
  if [[ "$tier" == "2" ]]; then
    nf_raise_alert "$addr"
  else
    "$GOTO" "$addr"
  fi
}

# Ask the notification's own app which of its windows sent it. Windows that
# share a process are indistinguishable by pid — ghostty runs with
# --gtk-single-instance, so every terminal window is the same pid — but the
# notification carries a "default" action the app wires to the exact
# originating window. Invoking it moves focus there; the caller then checks
# where we landed and undoes the jump if it wasn't something the user tagged.
invoke_default_action() {
  local id tries=0
  while ((tries < 20)); do
    # Match on the summary only: @tsv escapes newlines inside the body, so a
    # multi-line body would never compare equal to what mako actually holds.
    # Ghostty's ~1s notification cooldown means a same-summary collision in
    # this window is not really possible; newest id wins regardless.
    id=$(makoctl list -j 2>/dev/null | jq -r --arg s "$summary" \
      '[.[] | select(.summary == $s and (.actions | has("default"))) | .id] | max // empty')
    [[ -n "$id" ]] && break
    sleep 0.05
    ((tries++))
  done
  [[ -z "$id" ]] && { nf_log "no mako notification matched summary=$summary"; return 1; }
  nf_log "invoking default action on mako id=$id (after ${tries} polls)"
  makoctl invoke -n "$id" default >/dev/null 2>&1
}

# --- main loop ---------------------------------------------------------------

exec 8< <(stdbuf -oL busctl --user --json=short monitor \
  --match "interface=org.freedesktop.Notifications,member=Notify" 2>/dev/null)
BUSCTL_PID=$!

while IFS= read -r line <&8; do
  # Skip non-JSON lines (busctl prints a header)
  [[ "$line" != "{"* ]] && continue

  # Resolve the sender before anything else in this iteration forks. Pure bash
  # pattern matching, no jq — see snapshot_ancestry above for why.
  ancestry=()
  if [[ "$line" =~ \"sender-pid\":\{[^}]*\"data\":([0-9]+) ]]; then
    snapshot_ancestry "${BASH_REMATCH[1]}"
  fi

  # GApplication clients (ghostty among them) omit the sender-pid hint, so fall
  # back to resolving the D-Bus unique name. Those clients are long-lived, so
  # the extra round-trip is safe for them in a way it never is for notify-send.
  if ((${#ancestry[@]} == 0)) && [[ "$line" =~ \"sender\":\"([^\"]+)\" ]]; then
    sender_pid=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
      org.freedesktop.DBus GetConnectionUnixProcessID s "${BASH_REMATCH[1]}" 2>/dev/null | awk '{print $2}')
    [[ -n "$sender_pid" ]] && snapshot_ancestry "$sender_pid"
  fi

  ((${#ancestry[@]} == 0)) && continue

  # One jq pass for everything else we need off the wire. Split by hand rather
  # than with `IFS=$'\t' read`: tab counts as IFS whitespace, so bash would
  # collapse the empty app-name field that ghostty sends and shift every value
  # one place to the left. @tsv escapes any tab or newline inside a value, so
  # cutting on tabs here is safe.
  tsv=$(jq -r '[.payload.data[0], .payload.data[3], .payload.data[4],
                (if ((.payload.data[5] // []) | index("default")) then "yes" else "no" end)] | @tsv' <<<"$line")
  app_name="${tsv%%$'\t'*}"
  tsv="${tsv#*$'\t'}"
  summary="${tsv%%$'\t'*}"
  tsv="${tsv#*$'\t'}" # drops the body, which we don't need
  has_default="${tsv#*$'\t'}"

  # Ignore our own notifications
  [[ "$app_name" == "notify-focus" ]] && continue

  [[ -s "$NF_STATE_FILE" ]] || continue
  [[ "$(< "$NF_STATE_FILE")" == "[]" ]] && continue

  clients=$(hyprctl clients -j)

  # Drop tags whose windows have closed. We already have the client list, so
  # this costs nothing extra; without it a stale tag lingers until something
  # else calls nf_prune.
  pruned=$(jq -c --argjson c "$clients" \
    '[.[] | select(.address as $a | $c | any(.address == $a))]' "$NF_STATE_FILE")
  if [[ -n "$pruned" && "$pruned" != "$(jq -c . "$NF_STATE_FILE")" ]]; then
    tmp=$(mktemp)
    printf '%s\n' "$pruned" > "$tmp" && mv "$tmp" "$NF_STATE_FILE"
  fi
  [[ -z "$pruned" ]] && continue    # unreadable state file; skip this one
  [[ "$pruned" == "[]" ]] && exit 0 # nothing tagged any more

  # Tags belonging to the sending process or any of its forebears.
  anc_json="[$(IFS=,; echo "${ancestry[*]}")]"
  matches=$(jq -c --argjson anc "$anc_json" \
    '[.[] | select(.pid as $p | $anc | index($p))]' <<<"$pruned")
  match_count=$(jq length <<<"$matches")
  ((match_count == 0)) && continue

  # How many windows does that process own in total? More than one and the pid
  # alone cannot tell us which window notified — including the case where the
  # sender is an untagged sibling of a tagged window.
  owner_pid=$(jq -r '.[0].pid' <<<"$matches")
  win_count=$(jq --argjson p "$owner_pid" '[.[] | select(.pid == $p)] | length' <<<"$clients")
  nf_log "matched pid=$owner_pid tags=$match_count windows=$win_count default_action=$has_default summary=$summary"

  if ((win_count > 1)) && [[ "$has_default" == "yes" ]]; then
    prev_addr=$(hyprctl activewindow -j | jq -r '.address // empty')
    prev_ws=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .activeWorkspace.id')
    mapfile -t owner_addrs < <(jq -r --argjson p "$owner_pid" \
      '.[] | select(.pid == $p) | .address' <<<"$clients")

    if invoke_default_action; then
      # Wait for the app's activation to land. It has to land on a window of
      # the process that notified: accepting any focus change would misread a
      # click the user makes during this window as the activation, and we would
      # then "undo" a jump that never happened. Landing normally takes ~60ms.
      landed=""
      for _ in {1..40}; do
        sleep 0.05
        cur=$(hyprctl activewindow -j | jq -r '.address // empty')
        if [[ -n "$cur" && "$cur" != "$prev_addr" ]] && is_owner_window "$cur"; then
          landed="$cur"
          break
        fi
      done
      if [[ -z "$landed" ]]; then
        # Either the sending window already had focus (nothing to do) or the
        # activation never arrived. Both are safest handled by leaving focus be.
        nf_log "DECISION none: no activation onto a window of pid $owner_pid"
        continue
      fi
      nf_log "activation landed on $landed (was $prev_addr)"

      tier=$(jq -r --arg a "$landed" '.[] | select(.address == $a) | (.tier // 1)' <<<"$pruned")
      nf_log "landed window tier=${tier:-untagged}"
      case "$tier" in
      1)
        landed_ws=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .activeWorkspace.id')
        nf_record_prev "$prev_ws" "$landed_ws"
        nf_log "DECISION switch-to $landed"
        ;;
      2)
        # Tier 2 asked for a badge, not a jump — put focus back, then alert.
        restore_focus "$landed"
        nf_raise_alert "$landed"
        nf_log "DECISION alert-for $landed (focus returned to $prev_addr)"
        ;;
      *)
        # An untagged sibling window sent it. Undo the jump.
        restore_focus "$landed"
        nf_log "DECISION ignore $landed is untagged (focus returned to $prev_addr)"
        ;;
      esac
      continue
    fi
    # Could not invoke the action — fall through to the best-effort path.
  fi

  fallback_addr=$(jq -r '.[0].address' <<<"$matches")
  nf_log "DECISION fallback-to $fallback_addr (pid match only)"
  act_on "$fallback_addr" "$(jq -r '.[0].tier // 1' <<<"$matches")"
done
