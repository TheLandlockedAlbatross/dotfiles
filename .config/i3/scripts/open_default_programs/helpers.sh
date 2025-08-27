#!/bin/bash

# Helpers
num_of_open_windows() {
    # Get list of open windows
    xprop_result=$(xprop -root _NET_CLIENT_LIST_STACKING)
    # Use grep to find hex values and read them into an array
    mapfile -t open_windows < <(echo "${xprop_result}" | grep -o '0x[0-9a-f]\+')
    echo "${#open_windows[@]}"
}

num_of_non_floating_panes() {
    echo $(i3-msg -t get_tree | jq -r '.. | .nodes? // empty | .[] | select(.type=="con") |  select(.floating? == "auto_off") | {}' | wc -l)
}

pushd () {
    command pushd "$@" > /dev/null
}

popd () {
    command popd "$@" > /dev/null
}

run_cmd() {
    if [[ -n "${dry_flag}" ]]; then
        echo "${@}"
    else
        ${@}
    fi
}

# $1 : cmd to run
run_cmds_sequential() {
    idx=0
    WS="${FOCUSED_NUM}"
    SYM="${FOCUSED_SYM}"

    while [[ ${idx} -lt ${NUM_DISPLAYS} ]]; do
        if [[ -n "${dry_flag}" ]]; then
            old=$(num_of_non_floating_panes)
            target_ws="${WS}${SYM}"
            echo "i3-msg \"workspace \\\"${WS}${SYM}\\\"; exec ${1} &\""
            # Wait until in target workspace
            while true; do
                current_ws="$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused == true) | .name')"
                if [[ "${current_ws}" == "${target_ws}" ]]; then
                    sleep 0.1
                    break
                fi
            done
            # Block until number of open windows has increased
            while true; do
                current=$(num_of_non_floating_panes)
                if [[ ${current} -gt ${old} ]]; then
                    sleep 0.1
                    break
                fi
                #sleep 0.05
            done
            #sleep 0.5
        else
            old=$(num_of_non_floating_panes)
            target_ws="${WS}${SYM}"
            i3-msg "workspace \"${target_ws}\"; exec ${1} &"
            # Wait until in target workspace
            while true; do
                current_ws="$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused == true) | .name')"
                if [[ "${current_ws}" == "${target_ws}" ]]; then
                    sleep 0.1
                    break
                fi
            done
            # Block until number of open windows has increased
            while true; do
                current=$(num_of_non_floating_panes)
                if [[ ${current} -gt ${old} ]]; then
                    sleep 0.1
                    break
                fi
                #sleep 0.05
            done
            #sleep 0.5
        fi
        # Cycle back around to get all displays if starting on higher-numbered monitor
        if [[ $((WS+WS_PER_MONITOR)) -gt ${NUM_WS} ]]; then
            WS=$((WS-((NUM_DISPLAYS - 1) * WS_PER_MONITOR)))
        else
            WS=$((WS+WS_PER_MONITOR))
        fi
        idx=$((idx+1))
        shift
    done
    i3-msg workspace "${FOCUSED}"
}

run_cmds_if_visible() {
    idx=0
    WS=$FOCUSED
    #i3-msg -t get_workspaces | jq '.[] | select(.output == "HDMI-0" and .focused==true) | .name'
    while [[ ${idx} -lt ${NUM_DISPLAYS} ]]; do
        if [[ -n "${dry_flag}" ]]; then
            echo "i3-msg workspace ${WS}"
            echo "${1}"
        else
            i3-msg "workspace ${WS}; exec ${1} &; pid=$!; wait $!"
            sleep 0.5
        fi
        # Cycle back around to get all displays if starting on higher-numbered monitor
        if [[ $((WS+WS_PER_MONITOR)) -gt ${NUM_WS} ]]; then
            WS=$((WS-((NUM_DISPLAYS - 1) * WS_PER_MONITOR)))
        else
            WS=$((WS+WS_PER_MONITOR))
        fi
        idx=$((idx+1))
        shift
    done
    i3-msg workspace "${FOCUSED}"
}

# Command file
focused_command_file="${SCRIPT_DIR}/commands/${FOCUSED}-${command_flag}"
focused_command=""

change_command_file() {
    if [[ -z "${focused_command}" ]]; then
        # Default separator is | for yad
        IFS_BACKUP="${IFS}"
        IFS='|' read -r -a res < \
            <(yad --fixed --width=400 --height=100 \
                --image=i3_transparent --sticky --mouse \
                --selectable-labels \
                --form \
                --focus-field=3 \
                --field="Default program ${command_flag} for workspace ${FOCUSED} is not set!!:LBL" \
                --field="Enter default command ${command_flag} for workspace ${FOCUSED}\::LBL"  \
                --field=":CE" \
            )
        IFS="${IFS_BACKUP}"

        if [[ -n "${res[2]}" ]]; then
            mkdir -p $(dirname "${focused_command_file}")
            touch "${focused_command_file}"
            echo "${res[2]}" > "${focused_command_file}"
        fi
    else
        pushd "${SCRIPT_DIR}/commands"
        # CB and CBE fields for yad require a "" pair for each field before comboxbox
        combobox_quote_pairs='"" "" '
        #combobox_quote_pairs+=$(find . -type f -name "${FOCUSED}*-changed*" -exec printf '"" ' \;)
        # Entries must be separated by !
        combobox_entries=$(find . -type f -name "${FOCUSED}*-changed*" -print0 | xargs -0 cat | paste -sd '!' -)
        popd

        # echo "${combobox_quote_pairs}" > "${focused_command_file}test"
        # echo "${combobox_entries}" >> "${focused_command_file}test"
        # echo "$(pwd)" >> "${focused_command_file}test"

        # Default separator is | for yad
        IFS_BACKUP="${IFS}"
        IFS='|' read -r -a res < \
            <(yad --fixed --width=500 --height=100 \
                --image=i3_transparent --sticky --mouse \
                --selectable-labels \
                --form \
                --focus-field=5 \
                --field="\nDefault program ${command_flag} for workspace ${FOCUSED} is currently\:\n\n${focused_command}\n:LBL" \
                --field="Previous commands (for reference)\::LBL" \
                --field=":CBE" ${combobox_quote_pairs} "${combobox_entries}" \
                --field="\nEnter new default command ${command_flag} for workspace ${FOCUSED} \::LBL"  \
                --field=":CE" \
            )
        IFS="${IFS_BACKUP}"
        if [[ -n "${res[4]}" ]]; then
            mkdir -p $(dirname "${focused_command_file}")
            if [[ -f "${focused_command_file}" ]]; then
                mv "${focused_command_file}" "${focused_command_file}-changed_$(date +'%a_%Y%m%d_%H%M%S')"
            fi
            echo "${res[4]}" > "${focused_command_file}"
        fi
    fi
}

run_command_file() {
    if [[ ! -e "${focused_command_file}" ]]; then
        change_command_file
    elif [[ -n "${change_command_flag}" ]]; then
        read -r -d '' focused_command < "${focused_command_file}"
        change_command_file
    else
        source "${focused_command_file}"
    fi
}
