#!/bin/bash

# Omarchy dropdown to tag/untag any open window for notify-focus, from one
# central location. Tagged windows are marked by tier; select one to change it.
#   󰄰  untagged      󱐋  Tier 1 (auto-switch)      󰂚  Tier 2 (clickable alert)
# Loops so several windows can be managed in a row; Escape closes.

source "$HOME/.config/hypr/scripts/notify-focus-lib.sh"
nf_init
nf_prune

walker_menu() { # <prompt> — options on stdin
  omarchy-launch-walker --dmenu --width 360 --minheight 1 --maxheight 630 -p "$1…" 2>/dev/null
}

# Order windows by workspace: current workspace first, then ascending by id,
# then by class within a workspace.
cur_ws=$(hyprctl activeworkspace -j | jq '.id')
clients=$(hyprctl clients -j | jq --argjson cur "$cur_ws" \
  'sort_by([(if .workspace.id == $cur then 0 else 1 end), .workspace.id, (.class // "")])')

mapfile -t addrs < <(jq -r '.[].address' <<<"$clients")
mapfile -t lines < <(jq -r --slurpfile state "$NF_STATE_FILE" --argjson cur "$cur_ws" '
  .[] | . as $w
  | (($state[0] // []) | map(select(.address == $w.address)) | first) as $tag
  | ($tag | if . == null then "󰄰" elif (.tier // 1) == 2 then "󰂚" else "󱐋" end) as $marker
  | (if .workspace.id == $cur then "󰄯" else "󱂬" end) as $ws_icon
  | "\($marker)  \($ws_icon) \(.workspace.id) · \(.class // "?") — \((.title // "")[0:40])"
' <<<"$clients")

if [[ ${#lines[@]} -eq 0 ]]; then
  notify-send -a notify-focus -u low "Auto-focus" "No open windows"
  exit 0
fi

selected=$(printf '%s\n' "${lines[@]}" | walker_menu "Auto-focus")
[[ -z "$selected" ]] && exit 0

addr=""
for i in "${!lines[@]}"; do
  [[ "${lines[$i]}" == "$selected" ]] && { addr="${addrs[$i]}"; break; }
done
[[ -z "$addr" ]] && exit 0

win=$(jq -c --arg a "$addr" '.[] | select(.address == $a)' <<<"$clients")
label=$(jq -r '.class + " — " + (.title[0:40])' <<<"$win")
tier=$(nf_tier "$addr")

# Build the tier-chooser options based on current state.
if [[ -z "$tier" ]]; then
  choices="󱐋  Tier 1 — auto-switch\n󰂚  Tier 2 — notify"
elif [[ "$tier" == "2" ]]; then
  choices="󱐋  Switch to Tier 1 — auto-switch\n󰄰  Untag"
else
  choices="󰂚  Switch to Tier 2 — notify\n󰄰  Untag"
fi

action=$(echo -e "$choices" | walker_menu "$label")

case "$action" in
*"Tier 1"*)
  nf_tag "$addr" "$(jq -r '.pid' <<<"$win")" "$(jq -r '.class' <<<"$win")" "$(jq -r '.title' <<<"$win")" 1
  notify-send -a notify-focus -u normal "Auto-focus enabled (Tier 1)" "$label"
  ;;
*"Tier 2"*)
  nf_tag "$addr" "$(jq -r '.pid' <<<"$win")" "$(jq -r '.class' <<<"$win")" "$(jq -r '.title' <<<"$win")" 2
  notify-send -a notify-focus -u normal "Auto-focus enabled (Tier 2)" "$label"
  ;;
*Untag*)
  nf_untag "$addr"
  notify-send -a notify-focus -u low "Auto-focus disabled" "$label"
  ;;
*)
  exit 0 ;; # escaped the chooser — leave as-is, don't loop
esac

# Re-open so multiple windows can be managed in one session.
exec "$0"
