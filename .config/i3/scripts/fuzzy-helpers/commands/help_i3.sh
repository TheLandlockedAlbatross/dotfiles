#!/bin/sh


# list=$(i3-msg -t get_config | grep -E "^bindsym|^bindcode" | sed 's/^bindsym //;s/^bindcode //') | sed 's/\$mod/Super/g'


FZF_DEFAULT_OPTS="--height=100% --margin=0%,0%,0%,0% --layout=reverse --info=inline"

find "$HOME/.config/i3" -type f \( -name "config" -o -name "*.conf" \) -exec awk '{print FILENAME ": " $0}' {} + | \
    grep -E "bindsym|bindcode" | \
    sed "s|$I3_DIR/||" | \
    fzf --layout=reverse --header "Search all i3 Configs"
