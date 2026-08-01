#!/bin/bash
# Set the internal panel's refresh rate from the power source: AC -> AC_HZ, battery -> BAT_HZ.
#
# The panel's 180Hz mode costs roughly 1.5-3W over 60Hz at 2560x1600, which is a large
# share of idle draw (the SoC itself only pulls ~3.5W at idle).
#
# Runs as a daemon from autostart.conf. Re-applies on:
#   - power_supply udev events (AC plug/unplug, either USB-C port or the barrel jack)
#   - Hyprland monitor layout changes, because monitor-fallback.sh re-enables the panel
#     with "preferred", which snaps it back to 180Hz
#
# One-shot (no watchers):  refresh-autoset.sh once

set -uo pipefail

MONITOR=eDP-1
AC_HZ=180
BAT_HZ=60

# Scans every Mains+USB supply so USB-C charging counts, matching power-profile-autoset.
on_ac() {
  local ps t
  for ps in /sys/class/power_supply/*; do
    [[ -r "$ps/type" && -r "$ps/online" ]] || continue
    t=$(<"$ps/type")
    [[ "$t" == "Mains" || "$t" == "USB" ]] || continue
    [[ "$(<"$ps/online")" == "1" ]] && return 0
  done
  return 1
}

apply() {
  local hz geo res pos scale cur
  if on_ac; then hz=$AC_HZ; else hz=$BAT_HZ; fi

  # Read live geometry so we only ever change the refresh rate, and so a disabled or
  # absent panel (docked, lid closed) is skipped rather than force-enabled.
  #
  # Hyprland's monitor keyword takes all fields at once, so scale and position are
  # necessarily rewritten on every call. Whatever is live must be echoed back exactly:
  # substituting a default here would silently rescale the display. jq trims 2.00 -> 2
  # because Hyprland rejects some fractional scales it will happily report.
  geo=$(hyprctl monitors -j 2>/dev/null | jq -r --arg m "$MONITOR" \
    '.[] | select(.name==$m) | "\(.width)x\(.height) \(.x)x\(.y) \(.scale|tostring|sub("\\.0+$";"")) \(.refreshRate)"')
  [[ -z "$geo" ]] && return 0
  read -r res pos scale cur <<<"$geo"

  # Refuse to write a scale we did not read cleanly, rather than falling back to 1x.
  [[ "$scale" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
  [[ "$scale" == "0" ]] && return 0

  # refreshRate is fractional (180.00000, 59.99900), so round before comparing.
  [[ "$(printf '%.0f' "$cur")" == "$hz" ]] && return 0

  hyprctl keyword monitor "$MONITOR,${res}@${hz},${pos},${scale}"
}

[[ "${1:-daemon}" == "once" ]] && { apply; exit 0; }

# Let the initial layout settle before the first apply. monitor-fallback.sh is what
# establishes the panel's scale at login; applying before it would capture the scale
# from monitors.conf instead of the one that ends up on screen.
sleep 5
apply

udevadm monitor --udev --subsystem-match=power_supply 2>/dev/null | while read -r _; do
  apply
done &

# monitor-fallback.sh reasserts "preferred" on hot-unplug; re-apply after it settles.
sock="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"
socat -U - "UNIX-CONNECT:$sock" 2>/dev/null | while read -r line; do
  case "$line" in
    monitoradded*|monitorlayoutchanged*) sleep 0.5; apply ;;
  esac
done &

wait
