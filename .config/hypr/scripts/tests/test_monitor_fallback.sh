#!/bin/bash
# Tests for monitor-fallback.sh: which hotplug events it acts on, and how it
# behaves on a machine with no internal panel. The script is sourced, so no
# daemon starts; everything it calls out to is stubbed.
# Run: bash tests/test_monitor_fallback.sh

set -u
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export XDG_CONFIG_HOME="$TMP/config"
mkdir -p "$XDG_CONFIG_HOME/hypr/scripts" "$TMP/bin" "$TMP/drm"
cat > "$XDG_CONFIG_HOME/hypr/scripts/workspace-map.sh" <<STUB
#!/bin/bash
echo "wsmap \$*" >> "$TMP/calls.log"
STUB
chmod +x "$XDG_CONFIG_HOME/hypr/scripts/workspace-map.sh"

for cmd in logger swayosd-client; do
  cat > "$TMP/bin/$cmd" <<STUB
#!/bin/bash
echo "$cmd \$*" >> "$TMP/calls.log"
STUB
done
cat > "$TMP/bin/hyprctl" <<'STUB'
#!/bin/bash
[[ $1 == monitors ]] && echo '[{"name":"eDP-1"},{"name":"DP-1"}]' && exit 0
echo "hyprctl $*" >> "$CALLS"
STUB
chmod +x "$TMP"/bin/*
export CALLS="$TMP/calls.log"
PATH="$TMP/bin:$PATH"

FAILS=0
ck() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$3' got '$2'"; FAILS=$((FAILS+1)); fi; }
calls() { grep -c "$1" "$CALLS" 2>/dev/null; }

export DRM_DIR="$TMP/drm"
source "$SCRIPTS_DIR/monitor-fallback.sh"
sleep() { :; }   # the settle delays are not what is under test here

# --- which events reach the remap ----------------------------------------
ev() { : > "$CALLS"; handle_event "$1"; ck "$2" "$(calls '^wsmap apply')" "$3"; }
ev "monitoraddedv2>>4,DP-4,"    "display added remaps once"        1
ev "monitorremovedv2>>4,DP-4,"  "display removed remaps once"      1
ev "monitoradded>>DP-4"         "the v1 add is left to its v2"     0
ev "monitorremoved>>DP-4"       "the v1 remove is left to its v2"  0
ev "workspacev2>>3,3"           "workspace events are not ours"    0
ev "openwindow>>a,3,b,c"        "window events are not ours"       0

# One hotplug is one remap, not one per announcement.
: > "$CALLS"
handle_event "monitoradded>>DP-4"
handle_event "monitoraddedv2>>4,DP-4,"
ck "a hotplug remaps exactly once" "$(calls '^wsmap apply')" "1"

# --- no internal panel: say so once, then get on with it -----------------
: > "$CALLS"
PRIMARY=""; PRIMARY_RESOLVED=false; WARNED_NO_PRIMARY=false; PRIMARY_DISPLAY=""
check_monitors; check_monitors; check_monitors
ck "missing panel warns once"  "$(calls 'no internal panel')" "1"
ck "and only once"             "$(calls '^logger')" "1"
check_monitors; ck "still quiet later" "$(calls '^logger')" "1"

# --- an internal panel is found and used ---------------------------------
: > "$CALLS"
mkdir -p "$TMP/drm/card1-eDP-1" && touch "$TMP/drm/card1-eDP-1/status"
PRIMARY=""; PRIMARY_RESOLVED=false; WARNED_NO_PRIMARY=false
resolve_primary
ck "internal panel detected" "$PRIMARY" "eDP-1"
ck "no warning when there is one" "$(calls 'no internal panel')" "0"

# --- a configured primary short-circuits the search ----------------------
PRIMARY=""; PRIMARY_RESOLVED=false; PRIMARY_DISPLAY="DP-9"
resolve_primary
ck "configured primary wins" "$PRIMARY" "DP-9"

echo
if (( FAILS )); then echo "$FAILS FAILURE(S)"; exit 1; else echo "all monitor-fallback tests passed"; fi
