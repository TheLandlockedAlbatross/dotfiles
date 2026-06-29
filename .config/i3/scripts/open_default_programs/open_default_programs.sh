#!/bin/bash
###########################################################################
 # Name: open_default_programs.sh
 # Description: Open my chosen default programs in given workspace
 # Date: 03/18/2024
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
run_command_file
