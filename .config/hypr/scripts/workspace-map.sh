#!/bin/bash
# workspace-map.sh - machine-agnostic workspace->monitor mapping.
#
# Modes (persisted in ~/.local/state/hypr/workspace-map-mode):
#   decade         10 workspaces per display. Each display owns one decade for
#                  good: the first time a panel is seen it takes the lowest
#                  free slot, walking the layout bottom-right-most first then
#                  clockwise, and that pairing is written to the slot table and
#                  never recomputed. Unplug a display and only its own decade
#                  moves, to the least loaded survivor; nothing is renumbered
#                  and the other decades stay where they are. Hyprland brings
#                  the workspaces home by itself when the panel returns.
#   split          Odd workspaces on one display, even on the other (the old
#                  two-display system). Requires exactly two monitors.
#   split-flipped  Same with the two displays swapped.
#
# Commands:
#   apply   (default) resolve the mapping for the displays that are connected
#           right now, rewrite the managed block in monitors.conf (survives
#           hyprctl reload), apply the rules live, and re-home any workspace
#           sitting on the wrong display. Never touches monitor lines, only its
#           own marked block.
#   plan    print the rules apply would write, and the slot table behind them,
#           without changing anything
#   slots   print the slot table and who is currently hosting each decade
#   align   put every display on the same position within its own decade, so
#           position 3 means 3, 13, 23 and 33, each on the panel that owns that
#           decade. Takes the position as an argument (0 means 10, matching the
#           digit row); with no argument it takes the position of whatever
#           workspace is focused right now. Decades a display is only borrowing
#           because their owner is unplugged are left alone.
#   preview machine-readable version of what align would do: the mode, the
#           decade size, and the first workspace of each display's own decade
#           ("-" for a display that owns none). A caller can work out where
#           slot k lands without reimplementing any of this.
#   claim   hand a connected display with no decade one that is still owned by
#           a panel which is not here, preferring the decade it is already
#           hosting. For a replaced monitor: the old panel keeps its slot for
#           ever otherwise, and the new one silently sits outside align.
#   reset   forget the slot table and re-seed it from the current layout
#   toggle  cycle decade -> split -> split-flipped -> decade
#   mode    print the current mode
#
# Set WS_MAP_MONITORS_JSON to a `hyprctl monitors -j` payload to resolve against
# a hypothetical set of displays (used by the tests, and handy for answering
# "where would 21-30 go if I unplugged DP-1"). In that mode nothing durable is
# written: monitors.conf is left alone and no rules are pushed at the
# compositor, whichever command you run. WS_MAP_WORKSPACES_JSON does the same
# for the live workspace list, WS_MAP_CONF moves the rules file, and
# WS_MAP_DRY_RUN=1 makes `align` print the dispatches it would send instead of
# sending them.

set -o pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
CONF="${WS_MAP_CONF:-$HOME/.config/hypr/monitors.conf}"
# Resolving against a hypothetical set of displays. Everything that would
# outlive the process is off: the rules file describes displays that are not
# plugged in, and pushing them at the compositor strands whatever is on the
# real ones. Only the slot table still moves, and that has its own override.
WHAT_IF=false
[[ -n ${WS_MAP_MONITORS_JSON:-} ]] && WHAT_IF=true
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr"
STATE_FILE="$STATE_DIR/workspace-map-mode"
SLOTS_FILE="$STATE_DIR/workspace-map-slots"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/hypr-workspace-map.lock"
BEGIN_MARK="# BEGIN workspace-map"
END_MARK="# END workspace-map"

# One decade per display. DECADES is not a property of the hardware, it is how
# many digit-row layers bindings.conf actually binds (Super, Caps, Super+Alt,
# Super+Caps), so growing it means adding a layer there too. Displays past that
# count own no decade: they still receive orphans and you can still throw
# windows at them, they just have no digit of their own.
DECADE_SIZE=10
DECADES=4
# Optional per-machine overrides for DECADES and DECADE_SIZE, same pattern as
# monitor-fallback.conf.
# shellcheck source=/dev/null
[[ -r "$SCRIPT_DIR/workspace-map.conf" ]] && source "$SCRIPT_DIR/workspace-map.conf"
WS_MAX=$(( DECADES * DECADE_SIZE ))

notify() {
  swayosd-client --custom-icon video-display --custom-message "$1" 2>/dev/null \
    || hyprctl notify -1 4000 0 "  $1  " >/dev/null
}

mode_get() { cat "$STATE_FILE" 2>/dev/null || echo decade; }
mode_set() { mkdir -p "$STATE_DIR" && echo "$1" > "$STATE_FILE"; }

monitors_json() {
  if [[ -n ${WS_MAP_MONITORS_JSON:-} ]]; then
    printf '%s' "$WS_MAP_MONITORS_JSON"
  else
    hyprctl monitors -j
  fi
}

# Same escape hatch for the live workspace list, so `align` can be exercised
# against a hypothetical session.
workspaces_json() {
  if [[ -n ${WS_MAP_WORKSPACES_JSON:-} ]]; then
    printf '%s' "$WS_MAP_WORKSPACES_JSON"
  else
    hyprctl workspaces -j
  fi
}

# "name<TAB>description" per display, ordered bottom-right-most first then
# clockwise around the centroid of the layout (screen coordinates, y grows
# downward).
#
# Mirrors are skipped: they show a copy of another output, so a workspace
# pinned to one would never be visible.
ordered_monitors_raw() {
  monitors_json | jq -r '
    def pi: 3.141592653589793;
    [.[] | select(.disabled == false)
         | select((.mirrorOf // "none") == "none")
         # The odd transforms are the 90 and 270 degree ones, which swap the
         # footprint on screen. hyprctl keeps reporting the unrotated mode
         # dimensions, so a rotated panel lands in the wrong place in the
         # ordering unless we swap them back here.
         | (((.transform // 0) % 2) == 1) as $rot
         | ((.scale // 1) as $s
            | {name,
               desc: (.description // ""),
               cx: (.x + ((if $rot then .height else .width end) / $s) / 2),
               cy: (.y + ((if $rot then .width else .height end) / $s) / 2)})] as $m
    | if ($m | length) == 0 then empty else
        (($m | map(.cx) | add) / ($m | length)) as $ccx
      | (($m | map(.cy) | add) / ($m | length)) as $ccy
      | ($m | map(. + {ang: atan2(.cy - $ccy; .cx - $ccx)})) as $ma
      | ($ma | max_by([.cy, .cx])) as $start
      | $ma
      | map(. + {rel: ((.ang - $start.ang) | if . < 0 then . + 2 * pi else . end)})
      | sort_by([.rel, .name])
      | .[] | "\(.name)\t\(.desc)"
      end'
}

# MON_NAMES in clockwise order; MON_KEY maps a connector to the panel identity
# the slot table is keyed on.
declare -a MON_NAMES=()
declare -A MON_KEY=()
load_monitors() {
  local name desc i
  local -a names=() descs=()
  local -A desc_count=()
  MON_NAMES=(); MON_KEY=()
  while IFS=$'\t' read -r name desc; do
    [[ -n $name ]] || continue
    names+=("$name"); descs+=("$desc")
    [[ -n $desc ]] && (( desc_count["$desc"] += 1 ))
  done < <(ordered_monitors_raw)
  for i in "${!names[@]}"; do
    name=${names[$i]}; desc=${descs[$i]}
    MON_NAMES+=("$name")
    # Identity is the description, which carries the panel's serial, so a
    # decade follows its panel even if the cable moves to another port. Fall
    # back to the connector when there is no description (headless outputs) or
    # when two panels report the same one, which is all the identity there is.
    if [[ -n $desc && ${desc_count["$desc"]} -eq 1 ]]; then
      MON_KEY["$name"]="$desc"
    else
      MON_KEY["$name"]="$name"
    fi
  done
}

# SLOT_OF maps a panel identity to its decade index; OWNER is the reverse.
declare -A SLOT_OF=()
declare -a OWNER=()
load_slots() {
  local slot key
  SLOT_OF=(); OWNER=()
  [[ -r $SLOTS_FILE ]] || return 0
  while IFS=$'\t' read -r slot key; do
    [[ $slot =~ ^[0-9]+$ && -n $key ]] || continue
    (( slot < DECADES )) || continue
    SLOT_OF["$key"]=$slot
    OWNER[$slot]="$key"
  done < "$SLOTS_FILE"
  return 0
}

# Written through a temp file and renamed: plan and slots seed the table too,
# so a reader can arrive mid-write, and a truncated table would silently hand
# a panel somebody else's decade.
save_slots() {
  local slot tmp
  mkdir -p "$STATE_DIR" || return 1
  tmp=$(mktemp "$SLOTS_FILE.XXXXXX") || return 1
  for (( slot = 0; slot < DECADES; slot++ )); do
    [[ -n ${OWNER[$slot]:-} ]] && printf '%d\t%s\n' "$slot" "${OWNER[$slot]}"
  done > "$tmp"
  mv -f "$tmp" "$SLOTS_FILE" || { rm -f "$tmp"; return 1; }
  return 0
}

# Hand a slot to any connected panel that does not have one yet, lowest free
# slot first, in layout order. Existing pairings are never revisited: that is
# the whole point of the table, and re-deriving them from live geometry is what
# used to shuffle every decade whenever one display went away.
seed_slots() {
  local name key slot changed=0
  for name in "${MON_NAMES[@]}"; do
    key=${MON_KEY[$name]}
    [[ -n ${SLOT_OF[$key]:-} ]] && continue
    for (( slot = 0; slot < DECADES; slot++ )); do
      [[ -z ${OWNER[$slot]:-} ]] || continue
      SLOT_OF["$key"]=$slot
      OWNER[$slot]="$key"
      changed=1
      break
    done
  done
  (( changed )) && save_slots
  return 0
}

# TARGET[slot] = the connector that hosts that decade right now.
declare -a TARGET=()
resolve_targets() {
  local -A load=()
  local name key kslot s best bestload bestdist dist
  TARGET=()
  for name in "${MON_NAMES[@]}"; do load["$name"]=0; done
  # A connected panel always keeps its own decade.
  for name in "${MON_NAMES[@]}"; do
    key=${MON_KEY[$name]}
    kslot=${SLOT_OF[$key]:-}
    [[ -n $kslot ]] || continue
    TARGET[$kslot]="$name"
    (( load["$name"] += 1 ))
  done
  # A decade whose owner is unplugged goes to the least loaded survivor, ties
  # broken by the shortest clockwise hop from the missing owner's slot, so it
  # lands next door rather than wherever Hyprland happened to connect first.
  for (( s = 0; s < DECADES; s++ )); do
    [[ -n ${TARGET[$s]:-} ]] && continue
    best=""; bestload=0; bestdist=0
    for name in "${MON_NAMES[@]}"; do
      key=${MON_KEY[$name]}
      kslot=${SLOT_OF[$key]:-}
      if [[ -n $kslot ]]; then
        dist=$(( (kslot - s + DECADES) % DECADES ))
      else
        # More panels than decades: it owns nothing, so it is the last resort.
        dist=$DECADES
      fi
      if [[ -z $best ]] \
        || (( load["$name"] < bestload )) \
        || { (( load["$name"] == bestload )) && (( dist < bestdist )); }; then
        best=$name; bestload=${load[$name]}; bestdist=$dist
      fi
    done
    [[ -n $best ]] || continue
    TARGET[$s]="$best"
    (( load["$best"] += 1 ))
  done
  return 0
}

# The one line worth saying about the current table, or nothing. Two different
# ways to end up with a display that owns no decade: more displays than the
# bindings have layers for, or a panel that was replaced while the one it
# replaced still holds the slot. Only the second is fixable, so they read
# differently.
advisory() {
  local name key s orphans=0 ghosts=0
  local -A live=()
  for name in "${MON_NAMES[@]}"; do live[${MON_KEY[$name]}]=1; done
  for name in "${MON_NAMES[@]}"; do
    [[ -n ${SLOT_OF[${MON_KEY[$name]}]:-} ]] || (( orphans += 1 ))
  done
  (( orphans )) || return 0
  for (( s = 0; s < DECADES; s++ )); do
    key=${OWNER[$s]:-}
    [[ -n $key && -z ${live[$key]:-} ]] && (( ghosts += 1 ))
  done
  if (( ghosts )); then
    printf '%d display(s) own no decade, %d still held by a panel that is not here (claim hands them over)\n' \
      "$orphans" "$ghosts"
  else
    printf '%d display(s) beyond the %d decades own no workspaces\n' "$orphans" "$DECADES"
  fi
}

# Print one "workspace = N, monitor:X[, default:true]" line per workspace.
gen_rules() {
  local mode="$1"
  local ws mon def d k
  if [[ $mode == split || $mode == split-flipped ]]; then
    local odd=${MON_NAMES[0]} even=${MON_NAMES[1]}
    if [[ $mode == split-flipped ]]; then odd=${MON_NAMES[1]}; even=${MON_NAMES[0]}; fi
    for ((ws = 1; ws <= WS_MAX; ws++)); do
      (( ws % 2 == 1 )) && mon=$odd || mon=$even
      def=""; (( ws <= 2 )) && def=", default:true"
      printf 'workspace = %d, monitor:%s%s\n' "$ws" "$mon" "$def"
    done
  else
    for (( d = 0; d < DECADES; d++ )); do
      mon=${TARGET[$d]:-}
      [[ -n $mon ]] || continue
      for (( k = 1; k <= DECADE_SIZE; k++ )); do
        ws=$((d * DECADE_SIZE + k)); (( ws > WS_MAX )) && break
        # default:true marks a display's own decade, never a borrowed one.
        def=""
        (( k == 1 )) && [[ ${MON_KEY[$mon]} == "${OWNER[$d]:-}" ]] && def=", default:true"
        printf 'workspace = %d, monitor:%s%s\n' "$ws" "$mon" "$def"
      done
    done
  fi
}

# Replace (or append) the managed block in monitors.conf, leaving everything
# else in the file byte-for-byte intact apart from trailing blank lines.
write_block() {
  $WHAT_IF && return 0
  local mode="$1"; shift
  local body tmp
  body=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) == 1 { skip = 1; next }
    index($0, e) == 1 { skip = 0; next }
    !skip' "$CONF" 2>/dev/null)
  tmp=$(mktemp) || return 1
  {
    [[ -n $body ]] && printf '%s\n\n' "$body"
    printf '%s (mode: %s); generated by workspace-map.sh, do not hand-edit\n' "$BEGIN_MARK" "$mode"
    printf '%s\n' "$@"
    printf '%s\n' "$END_MARK"
  } > "$tmp" && cat "$tmp" > "$CONF"
  rm -f "$tmp"
}

apply_rules() {
  $WHAT_IF && return 0
  local line ws mon cur batch=""
  for line in "$@"; do
    batch+="keyword workspace ${line#workspace = };"
  done
  [[ -n $batch ]] && hyprctl --batch "$batch" >/dev/null
  # Re-home existing workspaces that sit on the wrong display. Monitor drops
  # and mode changes scatter them and they never come back on their own.
  local -A where=()
  while IFS=$'\t' read -r ws mon; do
    where["$ws"]="$mon"
  done < <(workspaces_json | jq -r '.[] | "\(.id)\t\(.monitor)"')
  batch=""
  for line in "$@"; do
    ws=${line#workspace = }; ws=${ws%%,*}
    mon=${line#*monitor:}; mon=${mon%%,*}
    cur=${where["$ws"]:-}
    [[ -n $cur && $cur != "$mon" ]] && batch+="dispatch moveworkspacetomonitor $ws $mon;"
  done
  [[ -n $batch ]] && hyprctl --batch "$batch" >/dev/null
  return 0
}

# Load monitors, settle the mode, seed the slot table and resolve targets.
# Prints nothing; leaves MODE, MON_NAMES, SLOT_OF, OWNER and TARGET populated.
MODE=""
prepare() {
  MODE=$(mode_get)
  load_monitors
  (( ${#MON_NAMES[@]} == 0 )) && return 1
  if [[ $MODE != decade ]] && (( ${#MON_NAMES[@]} != 2 )); then
    MODE=decade
    mode_set decade
  fi
  load_slots
  seed_slots
  resolve_targets
  return 0
}

cmd_apply() {
  local rules msg
  prepare || exit 0
  $WHAT_IF && echo "what-if: monitors.conf and the live layout left alone" >&2
  mapfile -t rules < <(gen_rules "$MODE")
  write_block "$MODE" "${rules[@]}"
  apply_rules "${rules[@]}"
  # Say so rather than leaving a display silently outside the scheme.
  msg=$(advisory)
  if [[ $MODE == decade && -n $msg ]]; then
    logger -t workspace-map "$msg"
    notify "$msg"
  fi
}

# Hand a homeless display a decade whose owner is not here. Deliberately not
# automatic: unplug a panel for an hour and plug a different one in, and doing
# this behind your back would mean the first one comes back to nothing.
cmd_claim() {
  local name key s target old took=0
  local -A live=()
  prepare || exit 0
  for name in "${MON_NAMES[@]}"; do live[${MON_KEY[$name]}]=1; done
  for name in "${MON_NAMES[@]}"; do
    key=${MON_KEY[$name]}
    [[ -n ${SLOT_OF[$key]:-} ]] && continue
    # The lowest decade whose owner is absent. That is also the one already on
    # this display's screen: a display that owns nothing starts at zero load,
    # so resolve_targets hands it the first unowned decade it walks. Nothing
    # visible changes, and ownership starts matching what is in front of you.
    target=""
    for (( s = 0; s < DECADES; s++ )); do
      old=${OWNER[$s]:-}
      if [[ -n $old && -z ${live[$old]:-} ]]; then target=$s; break; fi
    done
    [[ -n $target ]] || continue
    old=${OWNER[$target]}
    unset "SLOT_OF[$old]"
    SLOT_OF[$key]=$target
    OWNER[$target]=$key
    live[$key]=1
    (( took += 1 ))
  done
  if (( took == 0 )); then
    notify "No decade to claim: every one belongs to a display that is here"
    return 0
  fi
  save_slots
  cmd_apply
  notify "$took decade(s) handed to the display(s) that are actually here"
}

cmd_plan() {
  prepare || exit 0
  gen_rules "$MODE"
}

cmd_slots() {
  local s owner host name
  prepare || exit 0
  printf 'mode: %s\n' "$MODE"
  printf 'decades: %s of %s workspaces\n' "$DECADES" "$DECADE_SIZE"
  printf 'connected: %s\n' "${MON_NAMES[*]}"
  for (( s = 0; s < DECADES; s++ )); do
    owner=${OWNER[$s]:-"(unassigned)"}
    host=${TARGET[$s]:-"(nowhere)"}
    printf 'ws %2d-%-3d owner: %-40s host: %s\n' \
      $((s * DECADE_SIZE + 1)) $(( (s + 1) * DECADE_SIZE )) "$owner" "$host"
  done
  for name in "${MON_NAMES[@]}"; do
    [[ -n ${SLOT_OF[${MON_KEY[$name]}]:-} ]] && continue
    printf 'no decade: %-12s (%s)\n' "$name" "${MON_KEY[$name]}"
  done
  advisory
}

# Send a batch of dispatches, or print it under WS_MAP_DRY_RUN so the tests can
# check what align decided without a live session to drive.
dispatch_batch() {
  [[ -n $1 ]] || return 0
  if [[ -n ${WS_MAP_DRY_RUN:-} ]]; then
    printf '%s\n' "${1//;/$'\n'}" | sed '/^$/d'
  else
    hyprctl --batch "$1" >/dev/null
  fi
  return 0
}

# Line up every display on the same position within its own decade: position 3
# means 3, 13, 23 and 33, each on the panel that owns that decade.
#
# Owned decades only. A display hosting a decade whose panel is unplugged is
# only borrowing it, and lining that up would put one screen in two places at
# once, so those are skipped and stay where the user left them.
cmd_align() {
  local want="${1:-}" k i name key slot ws cnt cur focused_mon focused_ws batch=""
  local -a amon=() aws=() order=()
  local -A windows=() where=()
  prepare || exit 0
  if [[ $MODE != decade ]]; then
    notify "Align needs the one-decade-per-display mode (Super+E cycles to it)"
    exit 0
  fi

  read -r focused_mon focused_ws < <(monitors_json \
    | jq -r 'first(.[] | select(.focused)) | "\(.name) \(.activeWorkspace.id)"')

  # 0 is the 10 key: the digit row runs 1..9 then 0, so the tenth position is
  # spelled the way the keyboard spells it.
  if [[ -n $want ]]; then
    [[ $want =~ ^[0-9]+$ ]] || { echo "usage: $0 align [0-$DECADE_SIZE]" >&2; exit 1; }
    (( want == 0 )) && want=$DECADE_SIZE
    (( want >= 1 && want <= DECADE_SIZE )) \
      || { echo "align: position out of range 1-$DECADE_SIZE" >&2; exit 1; }
    k=$want
  elif [[ $focused_ws =~ ^[0-9]+$ ]] && (( focused_ws >= 1 && focused_ws <= WS_MAX )); then
    k=$(( (focused_ws - 1) % DECADE_SIZE + 1 ))
  else
    # Focused on a special or out-of-range workspace: nothing to copy, so take
    # the first position rather than guessing.
    k=1
  fi

  for name in "${MON_NAMES[@]}"; do
    key=${MON_KEY[$name]}
    slot=${SLOT_OF[$key]:-}
    [[ -n $slot ]] || continue
    amon+=("$name"); aws+=( $(( slot * DECADE_SIZE + k )) )
  done
  (( ${#amon[@]} )) || exit 0

  # Visit the focused display last so focus ends where it started.
  for i in "${!amon[@]}"; do
    [[ ${amon[$i]} == "$focused_mon" ]] || order+=("$i")
  done
  for i in "${!amon[@]}"; do
    [[ ${amon[$i]} == "$focused_mon" ]] && order+=("$i")
  done

  while IFS=$'\t' read -r ws cur cnt; do
    where["$ws"]="$cur"; windows["$ws"]="$cnt"
  done < <(workspaces_json 2>/dev/null \
    | jq -r '.[] | "\(.id)\t\(.monitor)\t\(.windows // 0)"')

  # Toggle-back bookkeeping, same rule workspace-switch.sh uses: remember where
  # we came from only when both ends have windows, so an empty workspace never
  # becomes the thing Super+N toggles back to.
  ws=${aws[${order[-1]}]}
  if [[ $focused_ws =~ ^[0-9]+$ ]] && (( focused_ws != ws )) \
    && (( ${windows[$focused_ws]:-0} > 0 )) && (( ${windows[$ws]:-0} > 0 )); then
    if [[ -n ${WS_MAP_DRY_RUN:-} ]]; then
      printf 'prev %s\n' "$focused_ws"
    else
      echo "$focused_ws" > /tmp/hypr-workspace-prev
    fi
  fi

  # Paint first, against what the layout will be rather than what it is, so a
  # spanned wallpaper resolves to the span instead of flashing four solo
  # slices on the way there.
  if [[ -z ${WS_MAP_DRY_RUN:-} && -f /tmp/hypr-workspace-bg-map \
    && -r "$SCRIPT_DIR/bg-paint.lib.sh" ]]; then
    local pairs bg
    pairs=$(for i in "${!amon[@]}"; do printf '%s\t%s\n' "${amon[$i]}" "${aws[$i]}"; done)
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/bg-paint.lib.sh"
    BG_MONITORS_JSON=$(monitors_json | jq --argjson m \
      "$(jq -Rn --arg p "$pairs" '[$p | split("\n")[] | select(length > 0)
          | split("\t") | {name: .[0], ws: (.[1] | tonumber)}]')" '
      map(. as $mon | ([$m[] | select(.name == $mon.name) | .ws] | first) as $ws
          | if $ws then .activeWorkspace.id = $ws else . end)')
    for i in "${!amon[@]}"; do
      bg=$(sed -n "${aws[$i]}p" /tmp/hypr-workspace-bg-map)
      [[ -n $bg ]] && bg_paint "${amon[$i]}" "$bg"
    done
  fi

  for i in "${order[@]}"; do
    name=${amon[$i]}; ws=${aws[$i]}
    # Self-heal: a workspace stranded on another display by an unplug is pulled
    # home before we ask its owner to show it.
    cur=${where[$ws]:-}
    [[ -n $cur && $cur != "$name" ]] && batch+="dispatch moveworkspacetomonitor $ws $name;"
    batch+="dispatch focusmonitor $name;dispatch workspace $ws;"
  done
  dispatch_batch "$batch"
}

# See the header. One record per line, tab separated, so the align picker can
# redraw its preview on every keystroke without paying for a slot resolution
# each time.
cmd_preview() {
  local name key slot
  prepare || exit 0
  printf 'mode\t%s\n' "$MODE"
  printf 'size\t%d\n' "$DECADE_SIZE"
  for name in "${MON_NAMES[@]}"; do
    key=${MON_KEY[$name]}
    slot=${SLOT_OF[$key]:-}
    if [[ -n $slot ]]; then
      printf '%s\t%d\n' "$name" $(( slot * DECADE_SIZE + 1 ))
    else
      printf '%s\t-\n' "$name"
    fi
  done
}

cmd_reset() {
  rm -f "$SLOTS_FILE"
  cmd_apply
  notify "Workspace slots re-seeded from the current layout"
}

cmd_toggle() {
  local mode next
  mode=$(mode_get)
  load_monitors
  case $mode in
    decade)
      if (( ${#MON_NAMES[@]} == 2 )); then
        next=split
      else
        notify "Odd/even split needs exactly two displays"
        exit 0
      fi ;;
    split) next=split-flipped ;;
    *) next=decade ;;
  esac
  mode_set "$next"
  cmd_apply
  case $next in
    decade)        notify "Workspaces: 10 per display" ;;
    split)         notify "Workspaces: odd/even split" ;;
    split-flipped) notify "Workspaces: odd/even split (flipped)" ;;
  esac
}

# Serialize the commands that write. The hotplug listener and the login
# autostart can both reach apply, and each rewrite touches monitors.conf, the
# slot table and the live rules. Re-exec under flock rather than locking inside
# a function so every writing entry point is covered by the one guard.
case "${1:-apply}" in
  apply | reset | toggle | align | claim)
    if [[ -z ${WS_MAP_LOCKED:-} ]]; then
      export WS_MAP_LOCKED=1
      exec flock -w 10 "$LOCK_FILE" "$0" "$@"
    fi ;;
esac

case "${1:-apply}" in
  apply)  cmd_apply ;;
  align)  cmd_align "${2:-}" ;;
  plan)   cmd_plan ;;
  preview) cmd_preview ;;
  slots)  cmd_slots ;;
  claim)  cmd_claim ;;
  reset)  cmd_reset ;;
  toggle) cmd_toggle ;;
  mode)   mode_get ;;
  *) echo "usage: $0 [apply|align [0-9]|preview|plan|slots|claim|reset|toggle|mode]" >&2; exit 1 ;;
esac
