#!/bin/bash

# Timer control menu using walker dmenu (omarchy style)

menu() {
  local prompt="$1"
  local options="$2"
  echo -e "$options" | omarchy-launch-walker --dmenu --width 295 --minheight 1 --maxheight 630 -p "$prompt…" 2>/dev/null
}

get_timers() {
  playerctl -l 2>/dev/null | grep 'io.github.efogdev.mpris-timer'
}

timer_label() {
  local player="$1"
  local status
  status=$(playerctl -p "$player" status 2>/dev/null)
  local id="${player##*.run-}"

  case "$status" in
    Playing) echo "󰄿  Timer $id (playing)" ;;
    Paused)  echo "󰏤  Timer $id (paused)" ;;
    *)       echo "  Timer $id ($status)" ;;
  esac
}

show_action_menu() {
  local player="$1"
  local status
  status=$(playerctl -p "$player" status 2>/dev/null)

  local options=""
  if [[ "$status" == "Playing" ]]; then
    options="󰏤  Pause\n  Restart\n  Quit"
  else
    options="󰐊  Resume\n  Restart\n  Quit"
  fi

  local action
  action=$(menu "Action" "$options")

  case "$action" in
    *Pause*)   playerctl -p "$player" pause ;;
    *Resume*)  playerctl -p "$player" play ;;
    *Restart*) playerctl -p "$player" previous ;;
    *Quit*)    playerctl -p "$player" stop ;;
    *)         show_timer_list ;;
  esac
}

show_timer_list() {
  local timers
  timers=$(get_timers)

  if [[ -z "$timers" ]]; then
    notify-send "No active timers"
    return
  fi

  local count
  count=$(echo "$timers" | wc -l)

  if [[ "$count" -eq 1 ]]; then
    show_action_menu "$timers"
    return
  fi

  local options=""
  local -A label_map
  while IFS= read -r player; do
    local label
    label=$(timer_label "$player")
    label_map["$label"]="$player"
    [[ -n "$options" ]] && options="$options\n"
    options="$options$label"
  done <<< "$timers"

  local choice
  choice=$(menu "Timers" "$options")

  if [[ -n "$choice" && -n "${label_map[$choice]}" ]]; then
    show_action_menu "${label_map[$choice]}"
  fi
}

show_timer_list
