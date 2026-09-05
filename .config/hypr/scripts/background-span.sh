#!/bin/bash
# Span the current theme background across all displays while individual
# workspace backgrounds are OFF. In span mode the image is stretched over the
# combined monitor bounding box and each output gets its crop via one swaybg
# per output; span off runs no swaybg at all — the omarchy 4 shell's
# background service owns the wallpaper and follows background switches
# natively. A watcher re-renders the slices when the background link changes
# (omarchy-theme-bg-set only notifies the shell, never swaybg).
#
# State lives outside omarchy's toggles dir (omarchy 4 prunes flags it doesn't
# own — see the workspace-backgrounds incident).
#
#   background-span.sh toggle|on|off   flip/set span mode (repaints if active)
#   background-span.sh paint           apply disabled-mode wallpaper policy now
#   background-span.sh watch           watcher loop (started by paint; internal)
#   background-span.sh render          build slices only (for testing)

STATE_FILE=~/.local/state/background-span-on
WS_BG_STATE=~/.local/state/workspace-backgrounds-on
CURRENT_DIR="$HOME/.local/state/omarchy/current"
CURRENT_BG_LINK="$CURRENT_DIR/background"
SLICE_DIR="$HOME/.cache/bg-span"
WATCH_PID_FILE="$SLICE_DIR/watch.pid"

span_on() { [[ -f $STATE_FILE ]]; }
individual_on() { [[ -f $WS_BG_STATE ]]; }

# monitor lines: name x y logical_w logical_h phys_w phys_h
monitor_geometry() {
  hyprctl monitors -j | jq -r '.[] | select(.disabled == false) |
    (if (.transform % 2) == 1 then {pw: .height, ph: .width} else {pw: .width, ph: .height} end) as $p |
    "\(.name) \(.x) \(.y) \(($p.pw / .scale) | round) \(($p.ph / .scale) | round) \($p.pw) \($p.ph)"'
}

render_slices() {
  local img
  img=$(readlink -f "$CURRENT_BG_LINK") || return 1
  [[ -f $img ]] || return 1

  mkdir -p "$SLICE_DIR"
  local sig_new sig_old=""
  sig_new="$img:$(stat -c %Y "$img" 2>/dev/null):$(monitor_geometry | md5sum | cut -d' ' -f1)"
  [[ -f $SLICE_DIR/signature ]] && sig_old=$(cat "$SLICE_DIR/signature")
  [[ "$sig_new" == "$sig_old" ]] && return 0

  rm -f "$SLICE_DIR"/*.png
  # Bounding box of all monitors in logical (layout) pixels
  local minx=999999 miny=999999 maxx=0 maxy=0
  local name x y lw lh pw ph
  while read -r name x y lw lh pw ph; do
    (( x < minx )) && minx=$x
    (( y < miny )) && miny=$y
    (( x + lw > maxx )) && maxx=$((x + lw))
    (( y + lh > maxy )) && maxy=$((y + lh))
  done < <(monitor_geometry)
  local bw=$((maxx - minx)) bh=$((maxy - miny))
  (( bw > 0 && bh > 0 )) || return 1

  while read -r name x y lw lh pw ph; do
    magick "$img" -resize "${bw}x${bh}!" \
      -crop "${lw}x${lh}+$((x - minx))+$((y - miny))" +repage \
      -resize "${pw}x${ph}!" "$SLICE_DIR/$name.png" || return 1
  done < <(monitor_geometry)
  printf '%s' "$sig_new" > "$SLICE_DIR/signature"
}

watcher_running() {
  local pid
  pid=$(cat "$WATCH_PID_FILE" 2>/dev/null) || return 1
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null
}

stop_watcher() {
  local pid
  pid=$(cat "$WATCH_PID_FILE" 2>/dev/null)
  [[ -n $pid ]] && kill "$pid" 2>/dev/null
  rm -f "$WATCH_PID_FILE"
}

start_watcher() {
  watcher_running && return 0
  mkdir -p "$SLICE_DIR"
  setsid "$0" watch >/dev/null 2>&1 < /dev/null &
  disown 2>/dev/null
}

# Watch the current-state dir: theme/background switches replace the
# `background` symlink there. Re-paint on change; exit when span mode ends.
cmd_watch() {
  echo $$ > "$WATCH_PID_FILE"
  while span_on && ! individual_on; do
    inotifywait -qq -t 300 -e create -e moved_to -e delete -e attrib "$CURRENT_DIR" 2>/dev/null
    span_on || break
    individual_on && break
    sleep 0.3   # let the link settle
    paint_span_only
  done
  rm -f "$WATCH_PID_FILE"
}

paint_span_only() {
  render_slices || return 1
  pkill -x swaybg 2>/dev/null
  # uwsm-app spawns are async via its daemon: give any in-flight swaybg from a
  # previous paint time to land before ours so the kill above stays complete.
  sleep 0.4
  local name rest
  while read -r name rest; do
    setsid uwsm-app -- swaybg -o "$name" -i "$SLICE_DIR/$name.png" -m stretch >/dev/null 2>&1 &
  done < <(monitor_geometry)
}

paint() {
  # Individual backgrounds own the wallpaper; never fight awww.
  if individual_on; then stop_watcher; return 0; fi
  if span_on; then
    paint_span_only && start_watcher
  else
    stop_watcher
    # No swaybg: the omarchy shell's background service draws the wallpaper
    # and follows omarchy-theme-bg-set on its own.
    pkill -x swaybg 2>/dev/null
    return 0
  fi
}

case "${1:-toggle}" in
  on)  touch "$STATE_FILE" ;;
  off) rm -f "$STATE_FILE" ;;
  toggle)
    if span_on; then rm -f "$STATE_FILE"; else touch "$STATE_FILE"; fi
    ;;
  paint)  paint; exit $? ;;
  watch)  cmd_watch; exit $? ;;
  render) render_slices; exit $? ;;
  *) echo "Usage: $0 [toggle|on|off|paint|render]"; exit 1 ;;
esac

if span_on; then mode="spanned across displays"; else mode="per-display (shell-managed)"; fi
if individual_on; then
  notify-send "Background span" "${mode^} (takes effect when individual backgrounds are off)" -t 3000
else
  paint
  notify-send "Background span" "${mode^}" -t 3000
fi
