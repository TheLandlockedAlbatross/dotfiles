#!/bin/bash
# Super+W: close the active window, but when it belongs to a Hyprland group,
# confirm through the omarchy shell menu first (canonical select style) and
# offer closing just this tab or the whole group. Esc cancels.

win=$(hyprctl activewindow -j 2>/dev/null)
[[ -z $win || $win == "{}" ]] && exit 0

mapfile -t members < <(jq -r '.grouped[]? // empty' <<<"$win")
count=${#members[@]}

if (( count <= 1 )); then
  exec hyprctl dispatch killactive
fi

title=$(jq -r '.title // ""' <<<"$win")
choice=$(omarchy-menu-select "Close grouped window? (${title:0:40})" \
  "Close this window only" \
  "Close entire group ($count windows)") || exit 0

case "$choice" in
  "Close this window only")
    hyprctl dispatch killactive
    ;;
  "Close entire group"*)
    for addr in "${members[@]}"; do
      hyprctl dispatch closewindow "address:$addr" >/dev/null
    done
    ;;
esac
