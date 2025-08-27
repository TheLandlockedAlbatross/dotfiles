#!/bin/bash

# Set each monitor to highest refresh rate available
active_monitors=($(xrandr --listactivemonitors | awk '/\+/ {print $4}'))

for active_monitor in "${active_monitors[@]}"; do
    highest_rate=$(temp=$(xrandr | awk -v m="${active_monitor}" '$0 ~ m { getline; print }' | awk '/\*.*\+/') ; while IFS= read -r line;  do echo "${line}" | awk '{for(i=1;i<=NF;i++){ if($i ~ /[0-9]+\.[0-9]+/){printf "%s ", $i} } }' | sed 's/[\*\+]//g' | sed 's/\s/\n/g' | sort -gr | head -n 1; done <<< "${temp}")
    current_res=$(xrandr | awk -v m="${active_monitor}" '$0 ~ m { getline; print }' | awk '{print $1}')
    xrandr --output ${active_monitor} --mode ${current_res} --rate ${highest_rate}
done

