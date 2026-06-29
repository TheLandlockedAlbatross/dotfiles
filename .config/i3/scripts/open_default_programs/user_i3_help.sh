#!/bin/bash
###########################################################################
 # Name: user_i3_help.sh
 # Description: Provide quick help window about current i3 state
 # Date: 08/25/25
###########################################################################

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# Error/warning strings for logging
error_str="ERROR: $0"
warning_str="WARNING: $0"

# Args/Usage
dry_flag=""
command_flag="$1"
change_command_flag="$2"


# Get display/i3 constants
source "${SCRIPT_DIR}/constants.sh"

# Get helpers
source "${SCRIPT_DIR}/helpers.sh"

# Main
# Default separator is | for yad
IFS_BACKUP="${IFS}"
IFS='|' read -r -a res < \
    <(yad --fixed --width=500 --height=500 \
        --image=i3_transparent --sticky --mouse \
        --license="Unlicense" \
        --selectable-labels \
        --list \
        --tree \
        --column="Workspaces" a Focused 1:a "${FOCUSED}" b "Active (${ACTIVE_NUM})" 1:b "${ACTIVE}" \
    )
IFS="${IFS_BACKUP}"
