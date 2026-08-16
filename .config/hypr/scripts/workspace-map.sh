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
#   reset   forget the slot table and re-seed it from the current layout
#   toggle  cycle decade -> split -> split-flipped -> decade
#   mode    print the current mode
#
# Set WS_MAP_MONITORS_JSON to a `hyprctl monitors -j` payload to resolve against
# a hypothetical set of displays (used by the tests, and handy for answering
# "where would 21-30 go if I unplugged DP-1"). Only `plan` and `slots` are
# meaningful in that mode; `apply` would write rules for displays you do not
# have.

set -o pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
CONF="$HOME/.config/hypr/monitors.conf"
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
  done < <(hyprctl workspaces -j | jq -r '.[] | "\(.id)\t\(.monitor)"')
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
  local rules extra
  prepare || exit 0
  mapfile -t rules < <(gen_rules "$MODE")
  write_block "$MODE" "${rules[@]}"
  apply_rules "${rules[@]}"
  # Say so rather than leaving a display silently outside the scheme.
  extra=$(( ${#MON_NAMES[@]} - DECADES ))
  if [[ $MODE == decade ]] && (( extra > 0 )); then
    logger -t workspace-map "$extra display(s) beyond the $DECADES decades own no workspaces"
    notify "$extra display(s) past the $DECADES workspace layers, no decade of their own"
  fi
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
  apply | reset | toggle)
    if [[ -z ${WS_MAP_LOCKED:-} ]]; then
      export WS_MAP_LOCKED=1
      exec flock -w 10 "$LOCK_FILE" "$0" "$@"
    fi ;;
esac

case "${1:-apply}" in
  apply)  cmd_apply ;;
  plan)   cmd_plan ;;
  slots)  cmd_slots ;;
  reset)  cmd_reset ;;
  toggle) cmd_toggle ;;
  mode)   mode_get ;;
  *) echo "usage: $0 [apply|plan|slots|reset|toggle|mode]" >&2; exit 1 ;;
esac
