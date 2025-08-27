#!/bin/sh
active_window=$(xdotool getactivewindow)
~/.config/i3/scripts/fade.sh "$active_window" 0 2
i3-msg "[id=$active_window] kill"

