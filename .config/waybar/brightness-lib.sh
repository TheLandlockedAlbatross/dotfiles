#!/bin/bash
# Per-display brightness helpers. Source this file.
# Routes eDP-1 through brightnessctl; external displays through ddcutil over DDC/CI.
# Caches last-known value per monitor so the widget can poll without hitting i2c.

CACHE_DIR="/tmp/waybar-brightness"
BUS_MAP="$CACHE_DIR/bus-map"
mkdir -p "$CACHE_DIR"

# Sub-floor dimming for the internal panel (eDP-1).
# The amdgpu backlight bottoms out at brightnessctl 0% but the panel LED still
# emits light. Below that floor we keep dimming via hyprsunset's gamma (a flat
# output multiplier) so the screen can go darker than the hardware allows.
GAMMA_MIN=0           # allow a fully black (but powered) screen; keybind recovers it
GAMMA_SCROLL_STEP=5   # gamma points per scroll tick
GAMMA_CLICK_STEP=10   # gamma points per click
GAMMA_STATE="$CACHE_DIR/edp-gamma"   # our source of truth for the dim level

# hyprsunset applies gamma asynchronously, so reading it straight back races
# under rapid input. Track the level in a state file instead; seed from
# hyprsunset (or 100) the first time.
gamma_get() {
  if [[ -s "$GAMMA_STATE" ]]; then
    cat "$GAMMA_STATE"
    return
  fi
  local g
  g=$(hyprctl hyprsunset gamma 2>/dev/null)
  [[ "$g" =~ ^[0-9]+$ ]] || g=100
  echo "$g" > "$GAMMA_STATE"
  echo "$g"
}

gamma_set() {
  local g="$1"
  (( g < GAMMA_MIN )) && g=$GAMMA_MIN
  (( g > 100 )) && g=100
  hyprctl hyprsunset gamma "$g" >/dev/null 2>&1
  echo "$g" > "$GAMMA_STATE"
  echo "$g"
}

focused_monitor() {
  hyprctl monitors -j | jq -r '.[] | select(.focused == true).name'
}

# Prefer the waybar bar's own output (set by waybar for each bar instance);
# fall back to the hyprland-focused monitor for keybind-driven invocations.
target_monitor() {
  if [[ -n "$WAYBAR_OUTPUT_NAME" ]]; then
    echo "$WAYBAR_OUTPUT_NAME"
  else
    focused_monitor
  fi
}

refresh_bus_map() {
  ddcutil detect --terse 2>/dev/null | awk '
    /^Display [0-9]+/           { in_display=1; bus=""; mon=""; next }
    /^[A-Za-z]/                 { in_display=0 }
    in_display && /I2C bus:/    { bus=$NF; sub(".*i2c-","",bus) }
    in_display && /DRM connector:/ { mon=$NF; sub("^card[0-9]+-","",mon) }
    in_display && mon!="" && bus!="" { print mon, bus; mon=""; bus="" }
  ' > "$BUS_MAP"
}

ddc_bus_for() {
  [[ -s "$BUS_MAP" ]] || refresh_bus_map
  awk -v mon="$1" '$1==mon {print $2; exit}' "$BUS_MAP"
}

# read_brightness <monitor> -> integer 0-100 on stdout, or nothing.
read_brightness() {
  local mon="$1"
  if [[ "$mon" == "eDP-1" ]]; then
    brightnessctl -m 2>/dev/null | cut -d, -f4 | tr -d '%'
    return
  fi
  local cache="$CACHE_DIR/$mon"
  if [[ -s "$cache" ]]; then
    cat "$cache"
    return
  fi
  local bus
  bus=$(ddc_bus_for "$mon")
  [[ -z "$bus" ]] && return 1
  local val
  val=$(ddcutil --bus "$bus" --brief getvcp 10 2>/dev/null | awk '{print $4}')
  [[ -z "$val" ]] && return 1
  echo "$val" > "$cache"
  echo "$val"
}

# set_brightness <monitor> <value 0-100>
set_brightness() {
  local mon="$1" val="$2"
  (( val < 0 )) && val=0
  (( val > 100 )) && val=100
  if [[ "$mon" == "eDP-1" ]]; then
    brightnessctl set "${val}%" >/dev/null
  else
    local bus
    bus=$(ddc_bus_for "$mon")
    [[ -z "$bus" ]] && return 1
    echo "$val" > "$CACHE_DIR/$mon"
    ddcutil --bus "$bus" --noverify setvcp 10 "$val" >/dev/null 2>&1 &
  fi
  pkill -SIGRTMIN+11 waybar 2>/dev/null
  echo "$val"
}

# Combined dim control for eDP-1: backlight first, then gamma below the floor.
# Invariant: gamma is only reduced when backlight == 0, and is restored to 100
# before backlight rises again, so the two never fight. Sets OSD_KIND/OSD_VAL.
# Usage: edp_dim <signed-delta>   (e.g. +1/-1 for scroll, +10/-10 for click)
edp_dim() {
  local delta="$1"
  local bl g gstep
  bl=$(brightnessctl -m 2>/dev/null | cut -d, -f4 | tr -d '%')
  g=$(gamma_get)

  # Coarser gamma move for clicks (|delta|>=10) than for scroll ticks.
  if (( delta <= -10 || delta >= 10 )); then
    gstep=$GAMMA_CLICK_STEP
  else
    gstep=$GAMMA_SCROLL_STEP
  fi

  if (( delta < 0 )); then
    if (( bl > 0 )); then
      local nb=$(( bl + delta )); (( nb < 0 )) && nb=0
      brightnessctl set "${nb}%" >/dev/null
      OSD_KIND=backlight OSD_VAL=$nb
    else
      OSD_VAL=$(gamma_set "$(( g - gstep ))")
      OSD_KIND=gamma
    fi
  else
    if (( g < 100 )); then
      OSD_VAL=$(gamma_set "$(( g + gstep ))")
      OSD_KIND=gamma
    else
      local nb=$(( bl + delta )); (( nb > 100 )) && nb=100
      brightnessctl set "${nb}%" >/dev/null
      OSD_KIND=backlight OSD_VAL=$nb
    fi
  fi
  pkill -SIGRTMIN+11 waybar 2>/dev/null
}

# Show the OSD for whatever edp_dim just changed (backlight or gamma).
show_dim_osd() {
  local mon="$1"
  if [[ "$OSD_KIND" == "gamma" ]]; then
    local progress
    progress=$(awk "BEGIN { printf \"%.2f\", $OSD_VAL / 100 }")
    swayosd-client --monitor "$mon" \
      --custom-icon "weather-clear-night-symbolic" \
      --custom-progress "$progress" \
      --custom-progress-text "${OSD_VAL}% ☾" 2>/dev/null
  else
    show_osd "$mon" "$OSD_VAL"
  fi
}

show_osd() {
  local mon="$1" val="$2"
  local progress
  progress=$(awk "BEGIN { printf \"%.2f\", $val / 100 }")
  swayosd-client --monitor "$mon" \
    --custom-icon "display-brightness-symbolic" \
    --custom-progress "$progress" \
    --custom-progress-text "${val}%" 2>/dev/null
}
