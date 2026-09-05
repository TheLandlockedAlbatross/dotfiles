#!/bin/bash

# Per-workspace backgrounds — assigns a different theme background to each workspace.
# Uses awww (formerly swww) for flicker-free switching.
#
# Subcommands:
#   toggle   — Enable/disable the feature. Enabling always starts from the
#              theme: layout sidecars and images added from outside the theme
#              are discarded first, after warning about them.
#   apply N  — Set background for workspace N (called by workspace-switch.sh)
#   rebuild  — Regenerate the mapping cache (called by theme-set hook)
#   lock     — Freeze what is on screen: stop following workspaces, keep awww
#              and its current images (used by the layout editor when an
#              arrangement uses an image outside the theme)
#   paint-arrangement — repaint the locked arrangement at full resolution

BG_TMP="${BG_TMP:-/tmp}"
STATE_FILE=~/.local/state/workspace-backgrounds-on
CACHE_FILE="$BG_TMP/hypr-workspace-bg-map"
FRAME_DUR_FILE="$BG_TMP/hypr-workspace-bg-framedur"
CONF_FILE="$HOME/.config/omarchy/workspace-backgrounds.conf"
CURRENT_BG_LINK="$HOME/.config/omarchy/current/background"
# BASH_SOURCE, not $0: the tests source this file, and $0 would then point at
# the test script rather than at the scripts directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Layout-aware painting (bg_paint): spans/pan/zoom via pre-rendered slices,
# falling back to plain awww for images without a layout.
source "$SCRIPT_DIR/bg-paint.lib.sh"

# Everything the layout editor can add on top of the theme, all of it thrown
# away when the feature is switched back on. Sidecars are per-image pan/zoom/
# span layouts; the extras file lists images picked from outside the theme;
# the arrangement file plus the lock marker describe a frozen custom layout.
LAYOUT_DIR="$HOME/.config/omarchy/background-layouts/images"
EXTRA_FILE="$BG_TMP/hypr-bg-extra-images"
ARRANGE_FILE="$BG_ARRANGEMENT"
LOCK_MARK="$BG_TMP/hypr-bg-locked"
SLICE_DIR="$BG_TMP/hypr-bg-layout"

# Regenerate layout slices; no-op beyond logging if nothing has a layout.
render_layouts() {
  python3 "$SCRIPT_DIR/bg-layout.py" render-all >/dev/null 2>&1 || true
}

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
      for ws in {1..40}; do
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
      for ws in {1..40}; do
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
  for ws in {1..40}; do
    mapping+=("${bgs[$(( (ws - 1) % total ))]}")
  done
  printf '%s\n' "${mapping[@]}" > "$CACHE_FILE"
}

cmd_apply() {
  local ws="$1" monitor="$2"
  [[ $ws =~ ^[0-9]+$ ]] || return
  (( ws >= 1 )) || return
  [[ -f $CACHE_FILE ]] || return
  local bg total
  total=$(wc -l < "$CACHE_FILE")
  (( total > 0 )) || return
  # A display past the last decade lands on a workspace the map does not
  # reach. Wrap round the same way the map itself repeats the theme, rather
  # than leaving that screen on a black wall.
  bg=$(sed -n "$(( (ws - 1) % total + 1 ))p" "$CACHE_FILE")
  [[ -z $bg ]] && return
  if [[ -n $monitor ]]; then
    bg_paint "$monitor" "$bg"
  else
    awww img "$bg" --transition-type none >/dev/null 2>&1
  fi
}

# Apply each monitor's current active workspace background to that monitor only.
cmd_apply_all() {
  [[ -f $CACHE_FILE ]] || return
  local mons_json
  mons_json=$(hyprctl monitors -j)
  while IFS=$'\t' read -r mon ws; do
    [[ -n $mon && -n $ws ]] && BG_MONITORS_JSON="$mons_json" cmd_apply "$ws" "$mon"
  done < <(jq -r '.[] | select(.disabled == false) | "\(.name)\t\(.activeWorkspace.id)"' <<<"$mons_json")
}

count_layouts() { find "$LAYOUT_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l; }
count_extras()  { awk 'NF' "$EXTRA_FILE" 2>/dev/null | wc -l; }

discard_customizations() {
  find "$LAYOUT_DIR" -maxdepth 1 -name '*.json' -delete 2>/dev/null
  rm -f "$EXTRA_FILE" "$ARRANGE_FILE" "$LOCK_MARK"
  rm -rf "$SLICE_DIR"
}

# Warn before the toggle throws work away. omarchy's walker menu turns the
# warning into a real choice; without it the warning still goes out and the
# toggle carries on, because reverting to the theme is what it is for.
# Presets are not touched: they are recipes, not an arrangement.
confirm_discard() {
  local layouts="$1" extras="$2" what choice
  what="$layouts layout$( (( layouts == 1 )) || echo s)"
  (( extras )) && what+=" and $extras added image$( (( extras == 1 )) || echo s)"
  if command -v omarchy-menu-select >/dev/null; then
    choice=$(omarchy-menu-select "Discard $what and revert to theme?" \
      "Discard" "Keep, leave backgrounds as they are" 2>/dev/null)
    [[ $choice == Discard ]] || return 1
  else
    notify-send -u critical "Workspace Backgrounds" \
      "Discarding $what, reverting to the theme" -t 5000
  fi
  return 0
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
  rm -f "$SLICE_DIR/last-painted.tsv"
  render_layouts
  cmd_apply_all
  start_listener
}

do_disable() {
  stop_listener
  rm -f "$LOCK_MARK" "$ARRANGE_FILE"
  pkill -x awww-daemon 2>/dev/null
  sleep 0.1
  # Painter honors the span toggle (stretch across all displays vs per-display
  # fill); it also kills any leftover swaybg itself.
  "$SCRIPT_DIR/background-span.sh" paint
}

cmd_toggle() {
  if [[ -f $STATE_FILE ]]; then
    rm -f "$STATE_FILE" "$CACHE_FILE" "$FRAME_DUR_FILE"
    do_disable
    notify-send "Workspace Backgrounds" "Disabled" -t 2000
  else
    # Enabling is also the way back to a clean theme, so anything the layout
    # editor left behind goes now rather than fighting the per-workspace map.
    local layouts extras
    layouts=$(count_layouts)
    extras=$(count_extras)
    if (( layouts + extras > 0 )); then
      if ! confirm_discard "$layouts" "$extras"; then
        notify-send "Workspace Backgrounds" "Left as they are" -t 2000
        return
      fi
    fi
    discard_customizations
    mkdir -p "$(dirname "$STATE_FILE")"
    touch "$STATE_FILE"
    do_enable
    if (( layouts + extras > 0 )); then
      notify-send "Workspace Backgrounds" \
        "Enabled — $layouts layout(s) and $extras added image(s) discarded" -t 3000
    else
      notify-send "Workspace Backgrounds" "Enabled" -t 2000
    fi
  fi
}

# Freeze what is on screen: stop following workspace switches and drop the
# map, but leave awww and its current images alone. The layout editor calls
# this when an arrangement uses an image the map knows nothing about, so the
# two cannot fight over the wallpaper.
cmd_lock() {
  rm -f "$STATE_FILE" "$CACHE_FILE" "$FRAME_DUR_FILE"
  touch "$LOCK_MARK"
  # Not stopped, restarted: the listener still has to hear about displays
  # coming and going, and there may not be one running at all if the feature
  # was off when the layout editor locked an arrangement.
  start_listener
}

# Repaint a locked arrangement through the layout engine. The editor's live
# preview is rendered at half resolution, so without this the frozen desktop
# keeps those soft previews.
cmd_paint_arrangement() {
  [[ -r $ARRANGE_FILE ]] || return
  local mons_json mon img
  mons_json=$(hyprctl monitors -j)
  while IFS=$'\t' read -r mon img; do
    [[ -n $mon && -f $img ]] || continue
    BG_MONITORS_JSON="$mons_json" bg_paint "$mon" "$img"
  done < "$ARRANGE_FILE"
}

# Called from Hyprland autostart; restores the previously-toggled state
# without surfacing a notification.
cmd_startup() {
  if [[ ! -f $STATE_FILE ]]; then
    # Disabled mode: repaint over the autostart swaybg when span mode is on.
    [[ -f ~/.local/state/background-span-on ]] && "$SCRIPT_DIR/background-span.sh" paint
    return 0
  fi
  do_enable
}

# One event off Hyprland's IPC socket. Split out of the loop because which
# events matter depends on which mode the feature is in, that mode can change
# while the listener is running, and the whole thing is untestable inside a
# socat pipeline.
#
# Following workspaces: resync on anything that changes what is on a screen.
# Holding a locked arrangement: workspaces no longer decide the wallpaper, but
# a layout change still invalidates every slice cut for the old geometry, and a
# returning display comes back to a blank wall, so monitor events still count.
# Off: nothing, and the listener should not be running anyway.
#
# Hyprland emits both a plain and a v2 form of the monitor events; v2 is the
# one carrying the id and name, and matching only it keeps this to one pass.
handle_event() {
  local line="$1"
  if [[ -f $STATE_FILE ]]; then
    case "$line" in
      workspacev2\>\>*|focusedmon\>\>*|moveworkspacev2\>\>*|createworkspacev2\>\>*)
        cmd_apply_all
        ;;
      monitoraddedv2\>\>*|monitorremovedv2\>\>*)
        render_layouts
        cmd_apply_all
        ;;
    esac
  elif [[ -f $LOCK_MARK ]]; then
    case "$line" in
      monitoraddedv2\>\>*|monitorremovedv2\>\>*)
        render_layouts
        cmd_paint_arrangement
        ;;
    esac
  fi
}

# Listen on Hyprland's IPC event socket and resync backgrounds. Covers cases
# keybindings don't (mouse focus, scroll switches, window-driven moves) and,
# in either mode, displays coming and going.
cmd_listen() {
  [[ -f $STATE_FILE || -f $LOCK_MARK ]] || return
  local sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"
  [[ -S $sock ]] || return
  while IFS= read -r line; do
    handle_event "$line"
  done < <(socat -u "UNIX-CONNECT:$sock" -)
}

cmd_rebuild() {
  [[ -f $STATE_FILE ]] || return
  build_cache
  render_layouts
  cmd_apply_all
}

# Sourced rather than run: the tests reach the functions above without any of
# the dispatch below happening.
(return 0 2>/dev/null) && return

case "${1:-toggle}" in
  toggle)    cmd_toggle ;;
  apply)     cmd_apply "$2" "$3" ;;
  apply-all) cmd_apply_all ;;
  rebuild)   cmd_rebuild ;;
  listen)    cmd_listen ;;
  startup)   cmd_startup ;;
  lock)      cmd_lock ;;
  paint-arrangement) cmd_paint_arrangement ;;
  *)         echo "Usage: $0 {toggle|apply <ws> [monitor]|apply-all|rebuild|listen|startup|lock|paint-arrangement}" >&2; exit 1 ;;
esac
