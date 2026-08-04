#!/bin/bash
mon=$(hyprctl monitors -j | jq '.[] | select(.focused == true)')

name=$(echo "$mon" | jq -r '.name')
x=$(echo "$mon" | jq -r '.x')
y=$(echo "$mon" | jq -r '.y')
transform=$(echo "$mon" | jq -r '.transform')

# Read resolution, rate, and scale from monitors.conf — hyprctl can report
# a scale that differs from the configured value (e.g. auto-scaled HiDPI),
# which would cause the rotation command to silently change the scale.
# Scale from hyprctl (runtime value, may differ from config due to auto-scaling)
scale=$(echo "$mon" | jq -r '.scale')

# Resolution and rate from monitors.conf (always native landscape dimensions,
# unlike hyprctl which reports logical/post-transform dimensions)
config=$(grep -E "^\s*monitor\s*=\s*${name}[,]" ~/.config/hypr/monitors.conf | grep -v '^\s*#' | head -1)
res_rate=$(echo "$config" | cut -d',' -f2 | tr -d ' ')
phys_w=$(echo "$res_rate" | awk -Fx '{print $1}')
phys_h=$(echo "$res_rate" | awk -Fx '{print $2}' | cut -d'@' -f1)
rate=$(echo "$res_rate" | cut -d'@' -f2)

if [ "$transform" -eq 0 ]; then
    new_transform=1
    label="portrait"
else
    new_transform=0
    label="landscape"
fi

hyprctl keyword monitor "$name,${phys_w}x${phys_h}@${rate},${x}x${y},${scale},transform,${new_transform}"
notify-send "Display" "$name → $label" -t 2000
