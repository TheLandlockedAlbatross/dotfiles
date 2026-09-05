#!/bin/bash
# Span the current theme background across all displays while individual
# workspace backgrounds are OFF. In span mode the image is stretched over the
# combined monitor bounding box and each output gets its crop via one swaybg
# per output; span off restores the stock one-copy-per-monitor fill.
#
# State lives outside omarchy's toggles dir (omarchy 4 prunes flags it doesn't
# own — see the workspace-backgrounds incident).
#
#   background-span.sh toggle|on|off   flip/set span mode (repaints if active)
#   background-span.sh paint           paint the disabled-mode wallpaper now,
#                                      honoring span state (used by
#                                      workspace-backgrounds.sh do_disable/startup)
#   background-span.sh render          build slices only (for testing)

STATE_FILE=~/.local/state/background-span-on
WS_BG_STATE=~/.local/state/workspace-backgrounds-on
CURRENT_BG_LINK="$HOME/.config/omarchy/current/background"
SLICE_DIR="$HOME/.cache/bg-span"

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

paint() {
  # Individual backgrounds own the wallpaper; never fight awww.
  individual_on && return 0
  pkill -x swaybg 2>/dev/null
  sleep 0.1
  if span_on && render_slices; then
    local name rest
    while read -r name rest; do
      setsid uwsm-app -- swaybg -o "$name" -i "$SLICE_DIR/$name.png" -m stretch >/dev/null 2>&1 &
    done < <(monitor_geometry)
  else
    setsid uwsm-app -- swaybg -i "$CURRENT_BG_LINK" -m fill >/dev/null 2>&1 &
  fi
}

case "${1:-toggle}" in
  on)  touch "$STATE_FILE" ;;
  off) rm -f "$STATE_FILE" ;;
  toggle)
    if span_on; then rm -f "$STATE_FILE"; else touch "$STATE_FILE"; fi
    ;;
  paint)  paint; exit $? ;;
  render) render_slices; exit $? ;;
  *) echo "Usage: $0 [toggle|on|off|paint|render]"; exit 1 ;;
esac

if span_on; then mode="spanned across displays"; else mode="per-display fill"; fi
if individual_on; then
  notify-send "Background span" "${mode^} (takes effect when individual backgrounds are off)" -t 3000
else
  paint
  notify-send "Background span" "${mode^}" -t 3000
fi
