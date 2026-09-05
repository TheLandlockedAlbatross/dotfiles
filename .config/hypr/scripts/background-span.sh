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

  rm -f "$SLICE_DIR"/*.png "$SLICE_DIR"/*.jpg
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

  # One magick invocation, crops taken in SOURCE pixel space (each monitor's
  # share of the stretched image maps back to a source rect), so the image is
  # decoded once and interpolated once per slice. JPEG output: swaybg reads it
  # via gdk-pixbuf and it encodes an order of magnitude faster than PNG.
  local sw sh
  read -r sw sh < <(magick identify -format "%w %h" "$img")   # no trailing \n: read exits 1 but fills vars
  [[ $sw =~ ^[0-9]+$ && $sh =~ ^[0-9]+$ ]] || return 1
  local args=()
  while read -r name x y lw lh pw ph; do
    read -r cx cy cw ch < <(awk -v sw="$sw" -v sh="$sh" -v bw="$bw" -v bh="$bh" \
      -v x="$((x - minx))" -v y="$((y - miny))" -v w="$lw" -v h="$lh" 'BEGIN {
        printf "%d %d %d %d", int(x/bw*sw + 0.5), int(y/bh*sh + 0.5),
          int(w/bw*sw + 0.5), int(h/bh*sh + 0.5) }')
    args+=( \( +clone -crop "${cw}x${ch}+${cx}+${cy}" +repage \
      -resize "${pw}x${ph}!" -quality 92 -write "$SLICE_DIR/$name.jpg" +delete \) )
  done < <(monitor_geometry)
  magick "$img" "${args[@]}" null: || return 1
  printf '%s' "$sig_new" > "$SLICE_DIR/signature"
}

WATCH_LOCK="$SLICE_DIR/watch.lock"
PAINT_LOCK="$SLICE_DIR/paint.lock"

stop_watcher() {
  local pid
  pid=$(cat "$WATCH_PID_FILE" 2>/dev/null)
  [[ -n $pid ]] && kill "$pid" 2>/dev/null
  rm -f "$WATCH_PID_FILE"
}

start_watcher() {
  mkdir -p "$SLICE_DIR"
  # cmd_watch takes an exclusive flock; a second watcher exits immediately,
  # so blind-starting here can never stack watchers.
  setsid "$0" watch >/dev/null 2>&1 < /dev/null &
  disown 2>/dev/null
}

# Watch the current-state dir: theme/background switches replace the
# `background` symlink there. Re-paint on change; exit when span mode ends.
cmd_watch() {
  mkdir -p "$SLICE_DIR"
  exec 9>"$WATCH_LOCK"
  flock -n 9 || exit 0          # singleton: another watcher already runs
  echo $$ > "$WATCH_PID_FILE"
  while span_on && ! individual_on; do
    inotifywait -qq -t 300 -e create -e moved_to -e delete -e attrib "$CURRENT_DIR" 2>/dev/null
    span_on || break
    individual_on && break
    sleep 0.4   # let the link settle and coalesce the create/rename burst
    paint_span_only
  done
  rm -f "$WATCH_PID_FILE"
}

# awww updates each output in place: no swaybg kill/respawn churn, so there is
# no window where the wallpaper falls back to the shell's per-display fill and
# no flicker inviting double keypresses. Serialized under a paint lock so
# overlapping triggers queue instead of interleaving.
paint_span_only() {
  mkdir -p "$SLICE_DIR"
  (
    # Bounded wait: a leaked/stuck lock degrades to a skipped paint, never a
    # pileup of blocked painters.
    flock -w 10 8 || exit 1
    span_on || exit 0
    individual_on && exit 0
    render_slices || exit 1
    pkill -x swaybg 2>/dev/null   # clear any legacy fill instances
    if ! pgrep -x awww-daemon >/dev/null; then
      # 8>&- : the daemon must NOT inherit the paint lock fd, or it holds the
      # lock for life and every later paint times out.
      setsid uwsm-app -- awww-daemon >/dev/null 2>&1 8>&- &
      for _ in $(seq 1 30); do
        awww query >/dev/null 2>&1 && break
        sleep 0.1
      done
    fi
    local name rest
    while read -r name rest; do
      awww img -o "$name" "$SLICE_DIR/$name.jpg" --transition-type none 2>/dev/null
    done < <(monitor_geometry)
  ) 8>"$PAINT_LOCK"
}

paint() {
  # Individual backgrounds own the wallpaper; never fight its awww instance.
  if individual_on; then stop_watcher; return 0; fi
  if span_on; then
    paint_span_only && start_watcher
  else
    stop_watcher
    # Nothing of ours: the omarchy shell's background service draws the
    # wallpaper and follows omarchy-theme-bg-set on its own.
    pkill -x awww-daemon 2>/dev/null
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
