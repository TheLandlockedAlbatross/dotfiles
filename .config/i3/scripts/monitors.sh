#!/bin/bash
###########################################################################
 # Name: monitors.sh
 # Description: Adjust i3 monitors
 # Date: 03/18/2024
###########################################################################

# Error/warning strings for logging
error_str="ERROR: $0"
warning_str="WARNING: $0"

# Monitor info from xrandr
monitors=($(xrandr --listactivemonitors | awk '/\+/ {print $4}'))
monitor_coordinates=($(xrandr --listactivemonitors | awk 'NR>1 { if (match($3, /\+[0-9]+\+[0-9]+/, a)) print a[0] }'))

# i3 setup
# TODO: more than primary monitor
PRIMARY_DISPLAY=$(xrandr | grep " primary " | awk '{print $1}')

# If xsct service
xsct_brightness=1
xsct_temperature=3500
current_xsct_brightness="$(xsct | awk '{print $NF}')"
current_xsct_temperature="$(xsct | awk '{print $(NF-1)}')"
xsct 3500 1
#if [[ "${current_xsct_brightness}" -ne 1 || "${current_xsct_temperature}" -ne 3500 ]]; then
#    xsct ${xsct_temperature} ${xsct_brightness}
#fi

