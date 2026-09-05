#!/bin/bash

# Cycle the notify-focus state of the currently focused window:
#   untagged  ->  Tier 1 (auto-switch)  ->  Tier 2 (clickable alert)  ->  untagged
# The manager dropdown (SUPER SHIFT H) can set any state directly.

source "$HOME/.config/hypr/scripts/notify-focus-lib.sh"
nf_init

window=$(hyprctl activewindow -j)
address=$(jq -r '.address' <<<"$window")
pid=$(jq -r '.pid' <<<"$window")
class=$(jq -r '.class' <<<"$window")
title=$(jq -r '.title' <<<"$window")

if [[ -z "$address" || "$address" == "null" ]]; then
  notify-send -a notify-focus "No focused window"
  exit 1
fi

case "$(nf_tier "$address")" in
"")
  # untagged -> Tier 1
  nf_tag "$address" "$pid" "$class" "$title" 1
  notify-send -a notify-focus -u normal "Auto-focus: Tier 1 (auto-switch)" "$class — ${title:0:40}"
  ;;
1)
  # Tier 1 -> Tier 2
  nf_tag "$address" "$pid" "$class" "$title" 2
  notify-send -a notify-focus -u normal "Auto-focus: Tier 2 (alert)" "$class — ${title:0:40}"
  ;;
*)
  # Tier 2 -> untagged
  nf_untag "$address"
  notify-send -a notify-focus -u low "Auto-focus disabled" "$class — ${title:0:40}"
  ;;
esac
