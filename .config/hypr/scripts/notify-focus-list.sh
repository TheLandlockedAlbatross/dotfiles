#!/bin/bash

# Show all windows currently tagged for notify-focus auto-focus,
# in an omarchy-style notification popup.

source "$HOME/.config/hypr/scripts/notify-focus-lib.sh"
nf_init
nf_prune

count=$(jq length "$NF_STATE_FILE")

if [[ "$count" -eq 0 ]]; then
  notify-send -a notify-focus -u low "Auto-focus" "No tagged windows"
  exit 0
fi

body=$(jq -r 'map((if (.tier // 1) == 2 then "󰂚" else "󱐋" end) + " \(.class) — \(.title[0:40])") | join("\n")' "$NF_STATE_FILE")

notify-send -a notify-focus -u normal "Auto-focus — $count tagged" "$body"
