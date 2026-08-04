#!/bin/bash

# Toggleable sleep inhibitor with omarchy-style walker prompt.
#
# Usage:
#   sleep-inhibit.sh                       # walker prompt: time field, then confirm menu
#   sleep-inhibit.sh <duration...>         # set directly, e.g. "8h30m", "8:30:24", "8 and a half hours"
#   sleep-inhibit.sh show                  # notification with remaining time + fields
#   sleep-inhibit.sh clear                 # release the inhibitor
#   sleep-inhibit.sh parse <text>          # print parsed seconds (debug)
#   Optional CLI flags: --who <s> --why <s> --what <s>
#
# A bare number means hours. "inf"/"forever" holds until cleared or reboot.
# Backend is auto-detected: systemd-inhibit, elogind-inhibit,
# gnome-session-inhibit, or caffeinate (macOS). Only --what has functional
# effect (sleep blocks suspend); who/why are labels shown in inhibitor lists.
# who/why/what are best-effort mapped on the gnome/caffeinate backends.

set -euo pipefail

STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/sleep-inhibit"
STATE_FILE="$STATE_DIR/state"

DEF_WHAT="sleep"
DEF_WHO="keep-awake"
DEF_WHY="User requested keep-awake"

GLYPH_ON="󰅶"
GLYPH_OFF="󰾪"

VALID_WHAT="sleep|idle|shutdown|handle-power-key|handle-suspend-key|handle-hibernate-key|handle-lid-switch|handle-reboot-key"

notify() { # glyph headline [body] [notify-send opts...]
  local glyph="$1" headline="$2" body="${3:-}"
  if command -v omarchy-notification-send >/dev/null 2>&1; then
    omarchy-notification-send "$@"
  elif command -v notify-send >/dev/null 2>&1; then
    shift 2
    [[ $# -gt 0 && ${1:-} != -* ]] && shift
    notify-send "$@" "$glyph  $headline" "$body"
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$body\" with title \"$headline\"" >/dev/null 2>&1 || true
  else
    echo "$headline${body:+ · $body}" >&2
  fi
}

detect_backend() {
  local b
  for b in systemd-inhibit elogind-inhibit gnome-session-inhibit caffeinate; do
    if command -v "$b" >/dev/null 2>&1; then
      BACKEND=$b
      return 0
    fi
  done
  return 1
}

require_backend() {
  if ! detect_backend; then
    notify "$GLYPH_OFF" "Keep-awake unavailable" "No sleep inhibitor found. Install one of: systemd-inhibit, elogind-inhibit, gnome-session-inhibit (Linux) or caffeinate (macOS)" -u critical
    echo "sleep-inhibit: none of systemd-inhibit/elogind-inhibit/gnome-session-inhibit/caffeinate found in PATH" >&2
    exit 127
  fi
}

# Parse a human duration into seconds (prints "inf" for indefinite).
# Accepts: 8h30m · 8h 30m · 8:30 · 8:30:24 · 90m · 1.5h · 8 · 8 and a half
# hours · half an hour · an hour and a half · eight hours · forever
# POSIX awk only (no gawk extensions) so it runs on BSD/macOS awk too.
parse_duration() {
  awk '
  {
    s = tolower($0)
    gsub(/,/, " ", s); gsub(/-/, " ", s)
    gsub(/[[:space:]]+/, " ", s); gsub(/^ +| +$/, "", s)
    if (s == "") exit 1
    if (s ~ /^(inf|infinity|forever|always|indefinitely|until reboot)$/) { print "inf"; exit 0 }

    # clock form: H:MM or H:MM:SS
    if (s ~ /^[0-9]+:[0-9][0-9]?(:[0-9][0-9]?)?$/) {
      n = split(s, p, ":")
      if (p[2] + 0 > 59 || (n == 3 && p[3] + 0 > 59)) exit 1
      print p[1] * 3600 + p[2] * 60 + (n == 3 ? p[3] : 0)
      exit 0
    }

    s = " " s " "

    # number words
    n = split("one two three four five six seven eight nine ten eleven twelve", w, " ")
    for (i = 1; i <= n; i++) gsub(" " w[i] " ", " " i " ", s)
    gsub(/ fifteen /, " 15 ", s); gsub(/ twenty /, " 20 ", s)
    gsub(/ thirty /, " 30 ", s);  gsub(/ forty five /, " 45 ", s)
    gsub(/ forty /, " 40 ", s);   gsub(/ fifty /, " 50 ", s)
    gsub(/ sixty /, " 60 ", s);   gsub(/ ninety /, " 90 ", s)

    # "<num> and a half" -> "<num>.5"
    while (match(s, /[0-9]+ and a half/)) {
      rs = RSTART; rl = RLENGTH
      seg = substr(s, rs, rl); sub(/ and a half/, ".5", seg)
      s = substr(s, 1, rs - 1) seg substr(s, rs + rl)
    }
    # "half [an] <unit>" -> "0.5 <unit>"
    while (match(s, / half (an |a )?(hour|hr|minute|min|second|sec|day)/)) {
      rs = RSTART; rl = RLENGTH
      seg = substr(s, rs, rl); sub(/half (an |a )?/, "0.5 ", seg)
      s = substr(s, 1, rs - 1) seg substr(s, rs + rl)
    }
    # "[a] quarter [of] [an] hour" -> "0.25 hour"
    while (match(s, / (a )?quarter (of )?(an |a )?(hour|hr)/)) {
      rs = RSTART; rl = RLENGTH
      s = substr(s, 1, rs - 1) " 0.25 hour" substr(s, rs + rl)
    }
    # "a/an <unit>" -> "1 <unit>"
    while (match(s, / an? (hour|hr|minute|min|second|sec|day)/)) {
      rs = RSTART; rl = RLENGTH
      seg = substr(s, rs, rl); sub(/ an? /, " 1 ", seg)
      s = substr(s, 1, rs - 1) seg substr(s, rs + rl)
    }
    # "<num> <unit>[s] and a half" -> "<num>.5 <unit>"
    while (match(s, /[0-9]+ (hour|hr|minute|min|second|sec|day)s? and a half/)) {
      rs = RSTART; rl = RLENGTH
      seg = substr(s, rs, rl); sub(/ and a half/, "", seg)
      match(seg, /^[0-9]+/)
      seg = substr(seg, 1, RLENGTH) ".5" substr(seg, RLENGTH + 1)
      s = substr(s, 1, rs - 1) seg substr(s, rs + rl)
    }
    gsub(/ and /, " ", s)
    gsub(/^ +| +$/, "", s)

    # tokenize <number>[unit] sequences; unitless followers step down h->m->s
    total = 0; count = 0; nextu = "h"
    while (s != "") {
      if (!match(s, /^[0-9]+(\.[0-9]+)?/)) exit 1
      num = substr(s, 1, RLENGTH) + 0
      s = substr(s, RLENGTH + 1); sub(/^ +/, "", s)
      unit = ""
      if (match(s, /^(hours|hour|hrs|hr|h|minutes|minute|mins|min|m|seconds|second|secs|sec|s|days|day|d)/)) {
        unit = substr(s, 1, RLENGTH)
        s = substr(s, RLENGTH + 1); sub(/^ +/, "", s)
      }
      if (unit == "") unit = (count == 0) ? "h" : nextu
      if (unit ~ /^d/)                       { mult = 86400; nextu = "h" }
      else if (unit ~ /^h/)                  { mult = 3600;  nextu = "m" }
      else if (unit == "m" || unit ~ /^min/) { mult = 60;    nextu = "s" }
      else                                   { mult = 1;     nextu = "s" }
      total += num * mult
      if (++count > 8) exit 1
    }
    total = int(total + 0.5)
    if (total <= 0) exit 1
    print total
  }' <<<"$1"
}

fmt_duration() { # seconds -> "8h 30m"
  local t=$1 d h m out=""
  d=$((t / 86400)); t=$((t % 86400)); h=$((t / 3600)); m=$((t % 3600 / 60))
  ((d)) && out+="${d}d "
  ((h)) && out+="${h}h "
  ((m)) && out+="${m}m "
  [[ -z $out ]] && out="$((t % 60))s "
  echo "${out% }"
}

fmt_at() { # epoch, format -> local time string (GNU and BSD date)
  if date -d "@0" +%s >/dev/null 2>&1; then
    date -d "@$1" "$2"
  else
    date -r "$1" "$2"
  fi
}

until_text() { # $1=until-epoch -> " · until HH:MM" (with weekday if >1d away)
  if (($1 - $(date +%s) >= 86400)); then
    echo " · until $(fmt_at "$1" "+%a %H:%M")"
  else
    echo " · until $(fmt_at "$1" +%H:%M)"
  fi
}

# Loads S_PID S_UNTIL S_WHAT S_WHO S_WHY if a live inhibitor exists.
active_state() {
  [[ -f $STATE_FILE ]] || return 1
  {
    read -r S_PID S_UNTIL && read -r S_WHAT && read -r S_WHO && read -r S_WHY
  } <"$STATE_FILE" || return 1
  if ! kill -0 "$S_PID" 2>/dev/null; then
    rm -f "$STATE_FILE"
    return 1
  fi
}

remaining_text() { # requires active_state loaded
  if [[ $S_UNTIL == inf ]]; then
    echo "until cleared"
  else
    echo "$(fmt_duration $((S_UNTIL - $(date +%s)))) left"
  fi
}

do_clear() { # $1=quiet(optional)
  if active_state; then
    kill -TERM "$S_PID" 2>/dev/null || true # holder's trap kills the backend and removes state
    rm -f "$STATE_FILE"
    [[ ${1:-} == quiet ]] || notify "$GLYPH_OFF" "Keep-awake off" "System may sleep normally"
  else
    [[ ${1:-} == quiet ]] || notify "$GLYPH_OFF" "No keep-awake active" "" -u low
  fi
}

do_show() {
  if active_state; then
    local when=""
    [[ $S_UNTIL != inf ]] && when=$(until_text "$S_UNTIL")
    notify "$GLYPH_ON" "Keeping system awake" "$(remaining_text)${when}\nwhat=$S_WHAT · who=$S_WHO\nwhy=$S_WHY" -u low
  else
    notify "$GLYPH_OFF" "Not keeping system awake" "No sleep inhibitor is active" -u low
  fi
}

# Builds INHIBIT_CMD (a shell-quoted command string) for the detected backend.
build_inhibit_cmd() { # $1=sleep_arg(seconds|infinity) $2=what $3=who $4=why
  local sleep_arg=$1 what=$2 who=$3 why=$4 part flags=""
  case $BACKEND in
  systemd-inhibit | elogind-inhibit)
    printf -v INHIBIT_CMD '%s --mode=block --what=%q --who=%q --why=%q sleep %q' \
      "$BACKEND" "$what" "$who" "$why" "$sleep_arg"
    ;;
  gnome-session-inhibit)
    local IFS=':'
    for part in $what; do
      case $part in
      idle) flags+="--inhibit idle " ;;
      shutdown | handle-power-key | handle-reboot-key) flags+="--inhibit logout " ;;
      *) flags+="--inhibit suspend " ;;
      esac
    done
    printf -v INHIBIT_CMD 'gnome-session-inhibit %s--reason %q sleep %q' \
      "$flags" "$why ($who)" "$sleep_arg"
    ;;
  caffeinate)
    local cflags="-s" # -s: block system sleep (AC); -i: block idle sleep
    [[ $what == *idle* || $what == *sleep* ]] && cflags="-is"
    if [[ $sleep_arg == infinity ]]; then
      printf -v INHIBIT_CMD 'caffeinate %s' "$cflags"
    else
      printf -v INHIBIT_CMD 'caffeinate %s -t %q' "$cflags" "$sleep_arg"
    fi
    ;;
  esac
}

do_set() { # $1=seconds|inf  $2=what $3=who $4=why
  local secs=$1 what=$2 who=$3 why=$4 sleep_arg until label when=""
  do_clear quiet 2>/dev/null || true
  mkdir -p "$STATE_DIR"
  if [[ $secs == inf ]]; then
    sleep_arg="infinity"; until="inf"; label="until cleared"
  else
    sleep_arg=$secs; until=$(($(date +%s) + secs)); label="for $(fmt_duration "$secs")"
    when=$(until_text "$until")
  fi
  build_inhibit_cmd "$sleep_arg" "$what" "$who" "$why"
  # Detached holder: writes state, runs the backend, and on TERM (clear) or
  # natural expiry kills the backend's process tree and removes the state file.
  UNTIL=$until WHAT=$what WHO=$who WHY=$why SFILE=$STATE_FILE INHIBIT_CMD=$INHIBIT_CMD \
    nohup bash -c '
      child=""
      cleanup() {
        if [ -n "$child" ]; then
          pkill -TERM -P "$child" 2>/dev/null
          kill -TERM "$child" 2>/dev/null
        fi
        rm -f "$SFILE"
        exit 0
      }
      trap cleanup TERM INT
      printf "%s %s\n%s\n%s\n%s\n" "$$" "$UNTIL" "$WHAT" "$WHO" "$WHY" >"$SFILE"
      eval "$INHIBIT_CMD" >/dev/null 2>&1 &
      child=$!
      wait "$child" 2>/dev/null
      rm -f "$SFILE"
    ' >/dev/null 2>&1 &
  notify "$GLYPH_ON" "Staying awake $label" "Inhibiting: ${what}${when} · via $BACKEND"
}

valid_what() {
  local part parts
  IFS=':' read -ra parts <<<"$1"
  [[ ${#parts[@]} -gt 0 ]] || return 1
  for part in "${parts[@]}"; do
    [[ $part =~ ^($VALID_WHAT)$ ]] || return 1
  done
}

# Interactive confirm menu after a valid time: Enter starts immediately,
# or pick who/why/what to override the optional fields.
confirm_menu() { # $1=seconds|inf
  local secs=$1 what=$DEF_WHAT who=$DEF_WHO why=$DEF_WHY
  local timelabel choice input
  [[ $secs == inf ]] && timelabel="until cleared" || timelabel=$(fmt_duration "$secs")
  while true; do
    choice=$(printf '%s\n' \
      "$GLYPH_ON  Start · $timelabel" \
      "  who · $who" \
      "  why · $why" \
      "  what · $what" |
      omarchy-launch-walker --dmenu --width 400 --minheight 1 --maxheight 630 -p "Keep awake…" -c 1 2>/dev/null) || true
    case $choice in
    *Start*) do_set "$secs" "$what" "$who" "$why"; return 0 ;;
    *who*)
      input=$(omarchy-menu-input "who (label in inhibitor list)" || true)
      [[ -n $input ]] && who=$input
      ;;
    *why*)
      input=$(omarchy-menu-input "why (label in inhibitor list)" || true)
      [[ -n $input ]] && why=$input
      ;;
    *what*)
      input=$(omarchy-menu-input "what (colon-separated: sleep, idle, shutdown, handle-lid-switch…)" || true)
      if [[ -n $input ]]; then
        if valid_what "$input"; then
          what=$input
        else
          notify "$GLYPH_OFF" "Invalid what" "Use colon-separated values from: ${VALID_WHAT//|/, }" -u critical
        fi
      fi
      ;;
    *) return 0 ;; # escape = cancel
    esac
  done
}

prompt() {
  local hint="Keep awake for (e.g. 8h30m, clear, show)"
  if active_state; then
    hint="Keep awake · $(remaining_text) · time / clear / show"
  fi
  local input secs
  input=$(omarchy-menu-input "$hint" || true)
  [[ -z $input ]] && exit 0
  case $(printf '%s' "$input" | tr '[:upper:]' '[:lower:]') in
  clear | off | stop | cancel | none) do_clear ;;
  show | status) do_show ;;
  *)
    if secs=$(parse_duration "$input"); then
      confirm_menu "$secs"
    else
      notify "$GLYPH_OFF" "Couldn't parse \"$input\"" "Try 8h30m · 8:30 · 90m · 8 and a half hours" -u critical
      prompt
    fi
    ;;
  esac
}

# --- main ---

case ${1:-} in
show | status) do_show; exit 0 ;;
clear | off | stop) require_backend; do_clear; exit 0 ;;
parse) shift; parse_duration "$*"; exit $? ;;
esac

require_backend

if [[ $# -eq 0 ]]; then
  prompt
  exit 0
fi

# CLI: duration words plus optional --who/--why/--what flags
what=$DEF_WHAT who=$DEF_WHO why=$DEF_WHY
words=()
while [[ $# -gt 0 ]]; do
  case $1 in
  --who) who=$2; shift 2 ;;
  --why) why=$2; shift 2 ;;
  --what) what=$2; shift 2 ;;
  *) words+=("$1"); shift ;;
  esac
done

if ! valid_what "$what"; then
  echo "sleep-inhibit: invalid --what '$what' (allowed: ${VALID_WHAT//|/, })" >&2
  exit 1
fi

if secs=$(parse_duration "${words[*]}"); then
  do_set "$secs" "$what" "$who" "$why"
else
  echo "sleep-inhibit: couldn't parse duration '${words[*]}'" >&2
  notify "$GLYPH_OFF" "Couldn't parse \"${words[*]}\"" "Try 8h30m · 8:30 · 90m · 8 and a half hours" -u critical
  exit 1
fi
