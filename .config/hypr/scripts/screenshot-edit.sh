#!/bin/bash
# omarchy 3.x-style capture: grab the region (via omarchy-capture-screenshot,
# keeping its screen-freeze + hardware-cursor handling and clipboard/file save),
# then open the result straight in the editor for annotation.
#
# omarchy 4 defaults to save-then-notify and only opens the editor from the
# notification's action — which needs the shell's notification service. Hamlet
# runs mako, so that action never fires; opening the editor here restores the
# immediate-edit flow. Pass a mode (smart|region|windows|fullscreen); default
# smart. The capture prints the saved path (the .png line) on stdout.
editor="${OMARCHY_SCREENSHOT_EDITOR:-tensaku-edit}"
mode="${1:-smart}"

file=$(omarchy-capture-screenshot "$mode" slurp | grep -E '\.png$' | tail -n1)
[[ -n $file && -f $file ]] || exit 0   # empty = region select cancelled

exec "$editor" "$file"
