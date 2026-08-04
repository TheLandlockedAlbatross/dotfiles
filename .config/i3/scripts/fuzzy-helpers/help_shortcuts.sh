#!/bin/bash
###########################################################################
 # Name: help_shortcuts.sh
 # Description: Display a floating sticky yad window with shortcut help
 # Date: 02/09/26
###########################################################################

# Get focused monitor's resolution via xrandr
read -r width height < <(xrandr --query | grep ' connected' | grep -oP '\d+x\d+' | head -1 | tr 'x' ' ')

win_width=$((width / 2))
win_height=$((height * 3 / 4))
pos_x=$(( (width - win_width) / 2 ))
pos_y=$(( (height - win_height) / 2 ))

i3="${HOME}/.config/i3"

# Build file list from $i3
file_list=""
while IFS= read -r f; do
    file_list+="${f#"$i3"/}"$'\n'
done < <(find "$i3" -type f ! -path '*/venv/*' ! -path '*/__pycache__/*' ! -path '*/.git/*' | sort)

yad --text="Hello World" --sticky --on-top --fixed --undecorated \
    --image=i3_transparent \
    --width="$win_width" --height="$win_height" \
    --posx="$pos_x" --posy="$pos_y" \
    --list --search-column=1 --print-column=1 \
    --column="Files" \
    <<< "$file_list"
