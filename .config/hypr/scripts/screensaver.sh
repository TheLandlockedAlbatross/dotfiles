#!/bin/bash
# Keybinding screensaver launcher: auto-activates on single display, shows picker on multi.
# Idle-triggered screensaver is handled by the default omarchy-launch-screensaver.

# Exit early if we don't have tte
command -v ttfx &>/dev/null || exit 1

# Exit early if screensaver is already running
pgrep -f org.omarchy.screensaver && exit 0

# Respect screensaver toggle
[[ -f ~/.local/state/omarchy/toggles/screensaver-off ]] && exit 1

launch_on_monitor() {
  local m="$1"
  local terminal
  terminal=$(xdg-terminal-exec --print-id)

  hyprctl dispatch focusmonitor "$m"

  case $terminal in
  *Alacritty*)
    hyprctl dispatch exec -- \
      alacritty --class=org.omarchy.screensaver \
      --config-file /usr/share/omarchy/default/alacritty/screensaver.toml \
      -e omarchy-screensaver
    ;;
  *ghostty*)
    hyprctl dispatch exec -- \
      ghostty --class=org.omarchy.screensaver \
      --config-file=/usr/share/omarchy/default/ghostty/screensaver \
      --font-size=18 \
      -e omarchy-screensaver
    ;;
  *foot*)
    hyprctl dispatch exec -- \
      foot --app-id=org.omarchy.screensaver \
      --config=/usr/share/omarchy/default/foot/screensaver.ini \
      -e omarchy-screensaver
    ;;
  *kitty*)
    hyprctl dispatch exec -- \
      kitty --class=org.omarchy.screensaver \
      --override font_size=18 \
      --override window_padding_width=0 \
      -e omarchy-screensaver
    ;;
  *)
    omarchy-notification-send -g ✋ "Screensaver only runs in Alacritty, Foot, Ghostty, or Kitty"
    ;;
  esac
}

focused=$(hyprctl monitors -j | jq -r '.[] | select(.focused == true).name')
N=$(hyprctl monitors all -j | jq '[.[] | select(.disabled == false)] | length')

if (( N <= 1 )); then
  # Single monitor: launch directly
  for m in $(hyprctl monitors -j | jq -r '.[] | select(.disabled == false) | .name'); do
    launch_on_monitor "$m"
  done
else
  # Multi-monitor: show picker (walker retired in omarchy 4; use the shell menu)
  options=()
  for name in $(hyprctl monitors -j | jq -r '.[] | select(.disabled == false) | .name'); do
    if [[ "$name" == "$focused" ]]; then
      options+=("$name (focused)")
    else
      options+=("$name")
    fi
  done
  options+=("All")

  choice=$(omarchy-menu-select "Screensaver" "${options[@]}") || exit 0
  choice="${choice%% (*}"  # strip " (focused)" suffix

  if [[ "$choice" == "All" ]]; then
    for m in $(hyprctl monitors -j | jq -r '.[] | select(.disabled == false) | .name'); do
      launch_on_monitor "$m"
    done
  else
    launch_on_monitor "$choice"
  fi
fi

hyprctl dispatch focusmonitor "$focused"
