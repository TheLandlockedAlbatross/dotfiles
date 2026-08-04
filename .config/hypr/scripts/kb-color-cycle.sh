#!/bin/bash
# Cycle the keyboard backlight through a set of standard colors.
# Bound to SHIFT + XF86KbdLightOnOff (the key that otherwise cycles brightness).
# Current position is kept in /tmp so it resets on reboot. Brightness is left
# untouched, so this only changes the color, not the on/off level.

KB_COLOR=~/Changes/fixes/asusctl-keyboard-fix/kb-color
STATE_FILE=/tmp/kb-color-cycle-index

# name:hex pairs, in cycle order. NAME is shown as-is in the OSD.
COLORS=(
  "Red:ff0000"
  "Orange:ff5500"
  "Yellow:ffaa00"
  "Green:00ff00"
  "Cyan:00ffff"
  "Blue:0000ff"
  "Purple:8800ff"
  "Magenta:ff00ff"
  "White:ffffff"
  "Ethereal:797ED2"
)

# Advance from the last position, or start at the first colour.
index=0
if [[ -f $STATE_FILE ]]; then
  prev=$(<"$STATE_FILE")
  [[ $prev =~ ^[0-9]+$ ]] && index=$(( (prev + 1) % ${#COLORS[@]} ))
fi
echo "$index" >"$STATE_FILE"

entry="${COLORS[index]}"
name="${entry%%:*}"
hex="${entry##*:}"

"$KB_COLOR" set "$hex"

~/.config/hypr/scripts/swayosd-focused.sh \
  --custom-icon input-keyboard --custom-message "Keyboard color: $name"
