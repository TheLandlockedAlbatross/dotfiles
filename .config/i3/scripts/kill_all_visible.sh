NUM_DISPLAYS=$(xrandr | \grep -c " connected")
WS_PER_MONITOR=25
NUM_WS=$((NUM_DISPLAYS * WS_PER_MONITOR))

FOCUSED="$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused == true) | .name')"
FOCUSED_NUM=$(echo "${FOCUSED}" | tr -cd '[:digit:].')
FOCUSED_SYM=$(echo "${FOCUSED}" | tr -d '[:digit:].')

idx=0
WS="${FOCUSED_NUM}"
SYM="${FOCUSED_SYM}"

kill_all_visible() {
    i3-msg workspace "${1}"
    safety_2=0
    while true; do
        # Get the count of windows in the current workspace
        window_count=$(i3-msg -t get_tree | jq '[.. | objects | select(.type == "con" and .focused == true)] | length')

        # If there are no focused windows, break the loop
        if [[ "$window_count" -eq 0 || ${safety_2} -gt 50 ]]; then
            break
        fi

        # Kill the currently focused window
        i3-msg kill

        sleep 0.1

        safety_2=$(($safety_2+1))
    done
}

while [ ${idx} -lt ${NUM_DISPLAYS} ]; do
    target_ws="${WS}${SYM}"
    i3-msg "workspace \"${target_ws}\""
    # Wait until in target workspace
    safety=0
    while true; do
        current_ws="$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused == true) | .name')"
        echo "$current_ws $target_ws"
        echo "kill_all_visible \"${current_ws}\""
        if [[ "${current_ws}" == "${target_ws}" || ${safety} -gt 50 ]]; then
            sleep 0.1
            break
        fi
        safety=$(($safety+1))
    done
    # Cycle back around to get all displays if starting on higher-numbered monitor
    if [[ $((WS+WS_PER_MONITOR)) -gt ${NUM_WS} ]]; then
        WS=$((WS-((NUM_DISPLAYS - 1) * WS_PER_MONITOR)))
    else
        WS=$((WS+WS_PER_MONITOR))
    fi
    idx=$((idx+1))
done
i3-msg workspace "${FOCUSED}"
