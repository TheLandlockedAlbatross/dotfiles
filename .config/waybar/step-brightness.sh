#!/bin/bash
# Adjust brightness on focused display by a signed delta and show OSD.
source "$(dirname "$0")/brightness-lib.sh"

mon=$(target_monitor)
step="${1:-+1}"

# Internal panel: dim through the backlight, then gamma below the hardware floor.
if [[ "$mon" == "eDP-1" ]]; then
  edp_dim "$step"
  show_dim_osd "$mon"
  exit 0
fi

cur=$(read_brightness "$mon")
[[ -z "$cur" ]] && exit 0

step="${step#+}"
next=$(( cur + step ))
(( next < 0 )) && next=0
(( next > 100 )) && next=100

set_brightness "$mon" "$next" >/dev/null
show_osd "$mon" "$next"
