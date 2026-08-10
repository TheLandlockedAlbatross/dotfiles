#!/bin/bash
# Pop the SwayOSD volume overlay when the default sink's volume or mute changes
# from outside swayosd — e.g. the Bose QC35 II volume rocker, which adjusts the
# sink directly via AVRCP absolute volume and never touches the keybindings.
# A +0 delta makes swayosd display current volume without changing it.

get_state() {
  echo "$(pactl get-default-sink):$(pactl get-sink-volume @DEFAULT_SINK@ | grep -o '[0-9]*%' | head -1):$(pactl get-sink-mute @DEFAULT_SINK@)"
}

last=$(get_state)
pactl subscribe | grep --line-buffered "'change' on sink" | while read -r _; do
  cur=$(get_state)
  if [ "$cur" != "$last" ]; then
    last=$cur
    omarchy-swayosd-client --output-volume +0
  fi
done
