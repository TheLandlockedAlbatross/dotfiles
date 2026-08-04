#!/bin/bash
###########################################################################
 # Name: help-term_shortcuts.sh
 # Description: Open a floating sticky st terminal with shortcut help
 # Date: 02/09/26
###########################################################################

# Use a unique WM_CLASS so i3 can target this window
/usr/local/bin/st -c "help-term_shortcuts" -e $SHELL -ci ". $HOME/.$(basename $SHELL)rc ; /home/adam/.config/i3/scripts/fuzzy-helpers/commands/help_i3.sh"

