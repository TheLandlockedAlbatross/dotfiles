#!/bin/bash

# Claude Code Notification hook (registered in ~/.claude/settings.json).
# Acts on notify-focus tags directly, without depending on ghostty's
# notification relay: ghostty silently drops notifications sent less than ~1s
# apart process-wide, so two sessions finishing close together lose one — the
# daemon never sees it and the switch never happens. This hook fires on every
# Claude Code notification regardless.
#
# The window is identified with a title probe: write an OSC 0 title token to
# our own tty and see which Hyprland window's title changes. That is the only
# thing that can single out one window of a shared-pid app (every ghostty
# window is the same process). The probe blip is invisible — Claude Code
# rewrites its title continuously anyway, and we restore it regardless.
# Under tmux the token never reaches the outer window title, so we exit
# without acting and the daemon's relay path (when not dropped) still applies.

source "$HOME/.config/hypr/scripts/notify-focus-lib.sh"

cat >/dev/null # drain the hook's JSON payload; the tty identifies us, not it

# Nothing tagged — stay off the hot path.
[[ -s "$NF_STATE_FILE" ]] || exit 0
[[ "$(< "$NF_STATE_FILE")" == "[]" ]] && exit 0

# Find our controlling terminal: the hook runs with a pipe on stdin, but an
# ancestor (the claude process) holds the pts.
pid=$$ tty="" stat="" rest="" ppid=""
while [[ "$pid" =~ ^[0-9]+$ ]] && ((pid > 1)); do
  t=$(readlink "/proc/$pid/fd/0" 2>/dev/null)
  [[ "$t" == /dev/pts/* ]] && { tty="$t"; break; }
  stat=""
  read -r -d '' stat 2>/dev/null < "/proc/$pid/stat"
  [[ -z "$stat" ]] && break
  # Skip the parenthesised comm field, which may itself contain spaces.
  rest="${stat##*") "}"
  ppid="${rest#* }"
  pid="${ppid%% *}"
done
[[ -z "$tty" || ! -w "$tty" ]] && exit 0

# Title probe.
pre=$(hyprctl clients -j)
token="nf-probe-$$-$SRANDOM"
printf '\033]0;%s\033\\' "$token" > "$tty"
addr=""
for _ in {1..20}; do
  addr=$(hyprctl clients -j | jq -r --arg t "$token" \
    '[.[] | select(.title == $t) | .address] | first // empty')
  [[ -n "$addr" ]] && break
  sleep 0.05
done
if [[ -n "$addr" ]]; then
  old=$(jq -r --arg a "$addr" \
    '[.[] | select(.address == $a) | .title] | first // empty' <<<"$pre")
  [[ -n "$old" ]] && printf '\033]0;%s\033\\' "$old" > "$tty"
fi
[[ -z "$addr" ]] && exit 0

case "$(nf_tier "$addr")" in
1) "$HOME/.config/hypr/scripts/notify-focus-goto.sh" "$addr" ;;
2) nf_raise_alert "$addr" ;;
esac
exit 0
