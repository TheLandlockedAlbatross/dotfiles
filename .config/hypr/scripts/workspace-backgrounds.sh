#!/bin/bash

# Per-workspace backgrounds — assigns a different theme background to each workspace.
# Uses awww (formerly swww) for flicker-free switching.
#
# Subcommands:
#   toggle   — Enable/disable the feature
#   apply N  — Set background for workspace N (called by workspace-switch.sh)
#   rebuild  — Regenerate the mapping cache (called by theme-set hook)

STATE_FILE=~/.local/state/omarchy/toggles/workspace-backgrounds
CACHE_FILE="/tmp/hypr-workspace-bg-map"
FRAME_DUR_FILE="/tmp/hypr-workspace-bg-framedur"
CONF_FILE="$HOME/.config/omarchy/workspace-backgrounds.conf"
CURRENT_BG_LINK="$HOME/.config/omarchy/current/background"

# Read config value: cfg <key> <default>
cfg() {
  local val
  val=$(grep -m1 "^${1}=" "$CONF_FILE" 2>/dev/null | cut -d= -f2-)
  echo "${val:-$2}"
}

# Collect sorted background paths (same logic as omarchy-theme-bg-next)
get_backgrounds() {
  local theme_name
  theme_name=$(cat "$HOME/.config/omarchy/current/theme.name" 2>/dev/null)
  find -L \
    "$HOME/.config/omarchy/backgrounds/$theme_name/" \
    "$HOME/.config/omarchy/current/theme/backgrounds/" \
    -maxdepth 1 -type f -print0 2>/dev/null | sort -z | tr '\0' '\n'
}

# Resolve a basename to full path from the background list
resolve_bg() {
  local name="$1"
  get_backgrounds | grep -m1 "/${name}$"
}

# Build cache file: one line per workspace (line 1 = ws 1, line 2 = ws 2, ...)
build_cache() {
  local mode
  mode=$(cfg mode default)
  local -a mapping

  case $mode in
    odd-even)
      local odd_path even_path
      odd_path=$(resolve_bg "$(cfg odd "")")
      even_path=$(resolve_bg "$(cfg even "")")
      if [[ -z $odd_path || -z $even_path ]]; then
        mapfile -t bgs < <(get_backgrounds)
        [[ -z $odd_path ]] && odd_path="${bgs[0]}"
        [[ -z $even_path ]] && even_path="${bgs[1]:-${bgs[0]}}"
      fi
      for ws in {1..10}; do
        if (( ws % 2 == 1 )); then
          mapping+=("$odd_path")
        else
          mapping+=("$even_path")
        fi
      done
      ;;
    custom)
      local order_str
      order_str=$(cfg custom_order "")
      IFS=',' read -ra order <<< "$order_str"
      local resolved=()
      for name in "${order[@]}"; do
        local path
        path=$(resolve_bg "$name")
        [[ -n $path ]] && resolved+=("$path")
      done
      local total=${#resolved[@]}
      if (( total == 0 )); then
        build_default_cache
        return
      fi
      for ws in {1..10}; do
        mapping+=("${resolved[$(( (ws - 1) % total ))]}")
      done
      ;;
    *)
      build_default_cache
      return
      ;;
  esac

  printf '%s\n' "${mapping[@]}" > "$CACHE_FILE"
}

build_default_cache() {
  mapfile -t bgs < <(get_backgrounds)
  local total=${#bgs[@]}
  (( total == 0 )) && return
  local -a mapping
  for ws in {1..10}; do
    mapping+=("${bgs[$(( (ws - 1) % total ))]}")
  done
  printf '%s\n' "${mapping[@]}" > "$CACHE_FILE"
}

cmd_apply() {
  local ws="$1" monitor="$2"
  [[ $ws =~ ^[0-9]+$ ]] || return
  [[ -f $CACHE_FILE ]] || return
  local bg
  bg=$(sed -n "${ws}p" "$CACHE_FILE")
  [[ -z $bg ]] && return
  if [[ -n $monitor ]]; then
    awww img -o "$monitor" "$bg" --transition-type none >/dev/null 2>&1
  else
    awww img "$bg" --transition-type none >/dev/null 2>&1
  fi
}

# Apply each monitor's current active workspace background to that monitor only.
cmd_apply_all() {
  [[ -f $CACHE_FILE ]] || return
  while IFS=$'\t' read -r mon ws; do
    [[ -n $mon && -n $ws ]] && cmd_apply "$ws" "$mon"
  done < <(hyprctl monitors -j | jq -r '.[] | select(.disabled == false) | "\(.name)\t\(.activeWorkspace.id)"')
}

stop_listener() {
  pkill -f "workspace-backgrounds.sh listen" 2>/dev/null
}

start_listener() {
  stop_listener
  setsid "$0" listen >/dev/null 2>&1 < /dev/null &
  disown 2>/dev/null
}

do_enable() {
  pkill -x swaybg 2>/dev/null
  pkill -x awww-daemon 2>/dev/null
  sleep 0.1
  setsid uwsm-app -- awww-daemon >/dev/null 2>&1 &
  sleep 0.3
  # Cache 2-frame duration for sync sleep in workspace-switch.sh
  local hz
  hz=$(hyprctl monitors -j | jq '[.[] | select(.disabled == false) | .refreshRate] | max')
  awk -v hz="${hz:-60}" 'BEGIN { printf "%.4f", 2/hz }' > "$FRAME_DUR_FILE"
  build_cache
  cmd_apply_all
  start_listener
}

do_disable() {
  stop_listener
  pkill -x awww-daemon 2>/dev/null
  sleep 0.1
  pkill -x swaybg 2>/dev/null
  setsid uwsm-app -- swaybg -i "$CURRENT_BG_LINK" -m fill >/dev/null 2>&1 &
}

cmd_toggle() {
  if [[ -f $STATE_FILE ]]; then
    rm -f "$STATE_FILE" "$CACHE_FILE" "$FRAME_DUR_FILE"
    do_disable
    notify-send "Workspace Backgrounds" "Disabled" -t 2000
  else
    mkdir -p "$(dirname "$STATE_FILE")"
    touch "$STATE_FILE"
    do_enable
    notify-send "Workspace Backgrounds" "Enabled" -t 2000
  fi
}

# Called from Hyprland autostart; restores the previously-toggled state
# without surfacing a notification.
cmd_startup() {
  [[ -f $STATE_FILE ]] || return 0
  do_enable
}

# Listen on Hyprland's IPC event socket and resync backgrounds when the
# focused monitor or any monitor's active workspace changes. Covers cases
# keybindings don't (mouse focus, scroll switches, window-driven moves).
cmd_listen() {
  [[ -f $STATE_FILE ]] || return
  local sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"
  [[ -S $sock ]] || return
  # shellcheck disable=SC2034
  while IFS= read -r line; do
    case "$line" in
      workspacev2\>\>*|focusedmon\>\>*|moveworkspacev2\>\>*|createworkspacev2\>\>*)
        cmd_apply_all
        ;;
    esac
  done < <(socat -u "UNIX-CONNECT:$sock" -)
}

cmd_rebuild() {
  [[ -f $STATE_FILE ]] || return
  build_cache
  cmd_apply_all
}

case "${1:-toggle}" in
  toggle)  cmd_toggle ;;
  apply)   cmd_apply "$2" "$3" ;;
  rebuild) cmd_rebuild ;;
  listen)  cmd_listen ;;
  startup) cmd_startup ;;
  *)       echo "Usage: $0 {toggle|apply <ws> [monitor]|rebuild|listen|startup}" >&2; exit 1 ;;
esac
