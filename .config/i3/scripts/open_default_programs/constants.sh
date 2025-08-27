#!/bin/bash

# TODO: In general, find less hard-coded ways of setting these
NUM_DISPLAYS=$(xrandr | \grep -c " connected")
NUM_WS=$(grep -o '\$ws[0-9]\+' ~/.config/i3/conf/workspaces.conf | sort -u | wc -l)
WS_PER_MONITOR=$((( ${NUM_WS} / ${NUM_DISPLAYS})))

FOCUSED="$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused == true) | .name')"
FOCUSED_NUM=$(echo "${FOCUSED}" | tr -cd '[:digit:].')
FOCUSED_SYM=$(echo "${FOCUSED}" | tr -d '[:digit:].')