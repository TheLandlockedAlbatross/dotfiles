#!/bin/bash
# Double-tap dispatcher for the monitor layout picker.
#   single tap -> monitor selection menu (Setup > Monitors > Configure Layout)
#   double tap -> skip the menu, place the currently focused display
# The single-tap path costs one WINDOW of latency, since we have to wait long
# enough to know a second tap isn't coming.

WINDOW_NS=350000000  # 0.35s
STATE="${XDG_RUNTIME_DIR:-/tmp}/monitor-configure-tap"
CONFIGURE="$(dirname "$(readlink -f "$0")")/monitor-configure.sh"

now=$(date +%s%N)
last=$(cat "$STATE" 2>/dev/null)
[[ "$last" =~ ^[0-9]+$ ]] || last=0
echo "$now" >"$STATE"

# Second tap inside the window: the first tap is still sleeping and will notice
# the stamp changed, so it handles the dispatch. Nothing to do here.
(( now - last < WINDOW_NS )) && exit 0

sleep 0.35

if [[ "$(cat "$STATE" 2>/dev/null)" != "$now" ]]; then
    exec "$CONFIGURE" focused
else
    exec "$CONFIGURE"
fi
