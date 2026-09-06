#!/bin/bash
# Tests for workspace-app.sh: where a click counts as "on the desktop", what
# the picker rows contain, and how set / test / forget move the state around.
# hyprctl, omarchy-shell, uwsm-app and notify-send are stubbed on PATH, so no
# window is focused and nothing is launched.
# Run: bash tests/test_workspace_app.sh

set -u
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export WORKSPACE_APP_STATE="$TMP/state.json"
export WORKSPACE_APP_DIRS="$TMP/apps-local:$TMP/apps-system"
export WORKSPACE_APP_PROC="$TMP/proc"
mkdir -p "$HOME" "$TMP/apps-local" "$TMP/apps-system" "$TMP/bin" "$TMP/proc/100" "$TMP/proc/200"

# --- fake desktop entries and /proc ------------------------------------------
cat > "$TMP/apps-system/firefox.desktop" <<'EOF'
[Desktop Entry]
Name=Firefox
Exec=/usr/lib/firefox/firefox %u
Icon=firefox
StartupWMClass=firefox
[Desktop Action new-private-window]
Name=Private window
EOF
cat > "$TMP/apps-system/org.gnome.Nautilus.desktop" <<'EOF'
[Desktop Entry]
Name=Files
Exec=nautilus --new-window %U
Icon=org.gnome.Nautilus
EOF
cat > "$TMP/apps-system/code-oss.desktop" <<'EOF'
[Desktop Entry]
Name=Code
Exec=code-oss %F
Icon=vscodium
StartupWMClass=Code
EOF
# A local entry shadows the system one of the same name.
cat > "$TMP/apps-local/foot.desktop" <<'EOF'
[Desktop Entry]
Name=Foot (local)
Exec=foot
Icon=foot
EOF
cat > "$TMP/apps-system/foot.desktop" <<'EOF'
[Desktop Entry]
Name=Foot
Exec=foot
Icon=foot
EOF
echo "btime 1000000" > "$TMP/proc/stat"
# starttime is field 22; the comm in parens may hold spaces.
echo "100 (fire fox) S 1 1 1 0 -1 4194560 1 0 0 0 1 1 0 0 20 0 1 0 500000 1 1" > "$TMP/proc/100/stat"
echo "200 (foot) S 1 1 1 0 -1 4194560 1 0 0 0 1 1 0 0 20 0 1 0 900000 1 1" > "$TMP/proc/200/stat"

# --- stubs -------------------------------------------------------------------
export LOG="$TMP/calls.log"; : > "$LOG"
export CURSOR='{"x":100,"y":100}'
# Two monitors: DP-1 at 0,0 (2048x1152 logical, 26px bar), DP-3 below it.
export MONITORS='[
  {"name":"DP-1","x":0,"y":0,"width":2560,"height":1440,"scale":1.25,"transform":0,"disabled":false,"reserved":[0,26,0,0],"activeWorkspace":{"id":21},"specialWorkspace":{"id":0}},
  {"name":"DP-3","x":0,"y":1152,"width":2560,"height":1440,"scale":1.25,"transform":0,"disabled":false,"reserved":[0,26,0,0],"activeWorkspace":{"id":12},"specialWorkspace":{"id":0}}
]'
export CLIENTS='[
  {"class":"firefox","pid":100,"mapped":true,"hidden":false,"workspace":{"id":21},"at":[1024,26],"size":[1024,1126]},
  {"class":"foot","pid":200,"mapped":true,"hidden":false,"workspace":{"id":12},"at":[0,1178],"size":[2048,1126]},
  {"class":"Code","pid":300,"mapped":true,"hidden":false,"workspace":{"id":5},"at":[0,0],"size":[10,10]},
  {"class":"ghost","pid":400,"mapped":false,"hidden":false,"workspace":{"id":21},"at":[0,26],"size":[1024,1126]}
]'
cat > "$TMP/bin/hyprctl" <<'STUB'
#!/bin/bash
echo "hyprctl $*" >> "$LOG"
case "$*" in
  "-j cursorpos") echo "$CURSOR" ;;
  "-j monitors")  echo "$MONITORS" ;;
  "-j clients")   echo "$CLIENTS" ;;
  dispatch*)      echo ok ;;
esac
STUB
# The overlay: records the payload, answers from a file the tests rewrite.
cat > "$TMP/bin/omarchy-shell" <<'STUB'
#!/bin/bash
echo "omarchy-shell $1 $2 $3" >> "$LOG"
printf '%s' "$4" > "$TMP/payload.json"
sel=$(jq -r '.selectionFile' <<<"$4"); done=$(jq -r '.doneFile' <<<"$4")
[[ -s $TMP/answer ]] && cp "$TMP/answer" "$sel"
: > "$done"
echo ok
STUB
for cmd in uwsm-app notify-send; do
  cat > "$TMP/bin/$cmd" <<STUB
#!/bin/bash
echo "$cmd \$*" >> "$LOG"
STUB
done
chmod +x "$TMP"/bin/*
PATH="$TMP/bin:$PATH"
export TMP

WA="$SCRIPTS_DIR/workspace-app.sh"
FAILS=0
ok()    { echo "ok   $1"; }
bad()   { echo "FAIL $1: $2"; FAILS=$((FAILS+1)); }
check() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "want '$3', got '$2'"; fi; }
reset() { : > "$LOG"; rm -f "$TMP/answer" "$TMP/payload.json" "$WORKSPACE_APP_STATE"; }
launched() { grep -c "uwsm-app -- gtk-launch\|dispatch exec" "$LOG"; }
state() { jq -r "$1" "$WORKSPACE_APP_STATE" 2>/dev/null; }

# --- class resolution --------------------------------------------------------
check "basename match, local dir wins" "$("$WA" resolve foot | jq -r '.label')" "Foot (local)"
check "basename match is case-insensitive" "$("$WA" resolve FIREFOX | jq -r '.id')" "firefox"
check "dotted id resolves" "$("$WA" resolve org.gnome.Nautilus | jq -r '.label')" "Files"
check "StartupWMClass fallback" "$("$WA" resolve Code | jq -r '.id')" "code-oss"
check "only the main group is read" "$("$WA" resolve firefox | jq -r '.label')" "Firefox"
"$WA" resolve nope >/dev/null; check "unknown class fails" "$?" "1"

# --- pointer context ---------------------------------------------------------
CURSOR='{"x":100,"y":100}'
check "empty area of DP-1 is desktop" "$("$WA" context | jq -c '[.monitor,.workspace,.onDesktop]')" '["DP-1",21,true]'
CURSOR='{"x":1500,"y":500}'
check "over firefox is not desktop" "$("$WA" context | jq -r '.onDesktop')" "false"
CURSOR='{"x":100,"y":10}'
check "bar strip is not desktop" "$("$WA" context | jq -r '.onDesktop')" "false"
CURSOR='{"x":100,"y":1200}'
check "over foot on DP-3 is not desktop" "$("$WA" context | jq -c '[.monitor,.workspace,.onDesktop]')" '["DP-3",12,false]'
CURSOR='{"x":5,"y":5}'
check "unmapped window is ignored (bar wins here)" "$("$WA" context | jq -r '.onDesktop')" "false"
CURSOR='{"x":9000,"y":9000}'
check "off every monitor is not desktop" "$("$WA" context | jq -r '.onDesktop')" "false"

# --- click over a window does nothing ----------------------------------------
reset; CURSOR='{"x":1500,"y":500}'
"$WA" launch; check "launch over a window exits 0" "$?" "0"
check "launch over a window opens nothing" "$(grep -c omarchy-shell "$LOG")" "0"
"$WA" set; check "set over a window opens nothing" "$(grep -c omarchy-shell "$LOG")" "0"

# --- snapshot + rows ---------------------------------------------------------
reset
"$WA" snapshot
check "snapshot records resolvable running classes" "$(state '.recent | map(.id) | sort | join(",")')" "code-oss,firefox,foot"
check "snapshot lastUsed from /proc start time" "$(state '.recent[] | select(.id=="foot") | .lastUsed')" "1009000"
check "snapshot without /proc falls back to now" "$(( $(state '.recent[] | select(.id=="code-oss") | .lastUsed') > 1700000000 ))" "1"
check "snapshot does not count as a use" "$(state '.recent[] | select(.id=="foot") | .uses')" "0"
"$WA" snapshot
check "snapshot is idempotent" "$(state '.recent | length')" "3"
check "rows sorted newest first" "$("$WA" rows 12 | jq -r 'map(.id) | join(",")')" "code-oss,foot,firefox"
check "rows carry key/subtext/section" "$("$WA" rows 12 | jq -c '.[1] | [.key,.subtext,.section]')" '["desktop:foot","foot","recent"]'

# --- picking with no default opens the picker --------------------------------
reset; CURSOR='{"x":100,"y":1200}'
CLIENTS_SAVE=$CLIENTS
CLIENTS=$(jq -c 'map(select(.class != "foot"))' <<<"$CLIENTS")   # DP-3 now empty
echo '{"action":"set","row":{"kind":"desktop","id":"foot","label":"Foot (local)","icon":"foot","exec":"foot","file":"x","key":"desktop:foot","section":"recent"}}' > "$TMP/answer"
"$WA" launch
check "no default: picker summoned" "$(grep -c "omarchy-shell shell summon tla.workspace-apps" "$LOG")" "1"
check "payload names the workspace under the cursor" "$(jq -r '.workspace' "$TMP/payload.json")" "12"
check "payload has no current key yet" "$(jq -r '.currentKey' "$TMP/payload.json")" ""
check "set stores the default" "$(state '.defaults["12"].id')" "foot"
check "set strips picker fields" "$(state '.defaults["12"] | has("key")')" "false"
check "set records a use" "$(state '.recent[] | select(.id=="foot") | .uses')" "1"
# focusmonitor runs before the picker opens and again before the launch.
check "set focuses the monitor then launches" "$(grep -c "dispatch focusmonitor DP-3" "$LOG"):$(grep -c "uwsm-app -- gtk-launch foot.desktop" "$LOG")" "2:1"

# --- with a default, launch skips the picker ---------------------------------
: > "$LOG"
"$WA" launch
check "default launches without a picker" "$(grep -c omarchy-shell "$LOG"):$(grep -c "gtk-launch foot.desktop" "$LOG")" "0:1"
check "launch bumps uses" "$(state '.recent[] | select(.id=="foot") | .uses')" "2"

# --- set again: old default moves to previous --------------------------------
: > "$LOG"
echo '{"action":"set","row":{"kind":"desktop","id":"firefox","label":"Firefox","icon":"firefox","exec":"/usr/lib/firefox/firefox %u","file":"x"}}' > "$TMP/answer"
"$WA" set
check "set always summons the picker" "$(grep -c "omarchy-shell shell summon" "$LOG")" "1"
check "payload marks the current default" "$(jq -r '.currentKey' "$TMP/payload.json")" "desktop:foot"
check "payload rows lead with the current default" "$(jq -r '.rows[0] | [.id,.section] | join(":")' "$TMP/payload.json")" "foot:current"
check "new default stored" "$(state '.defaults["12"].id')" "firefox"
check "old default pushed to previous" "$(state '.previous["12"] | map(.id) | join(",")')" "foot"
echo '{"action":"set","row":{"kind":"desktop","id":"foot","label":"Foot (local)","icon":"foot","exec":"foot","file":"x"}}' > "$TMP/answer"
"$WA" set
check "re-setting an earlier default removes it from previous" "$(state '.previous["12"] | map(.id) | join(",")')" "firefox"
check "rows: current, previous, then recent, deduped" "$("$WA" rows 12 | jq -r 'map(.id + "/" + .section) | join(",")')" "foot/current,firefox/previous,code-oss/recent"
check "rows know which workspaces use an entry" "$("$WA" rows 12 | jq -c '.[0].defaultFor')" "[12]"

# --- test action launches without setting -------------------------------------
: > "$LOG"
echo '{"action":"test","row":{"kind":"command","exec":"firefox -P TLA","label":"firefox -P TLA"}}' > "$TMP/answer"
"$WA" set
check "test runs a command through hyprland exec" "$(grep -c "dispatch exec firefox -P TLA" "$LOG")" "1"
check "test leaves the default alone" "$(state '.defaults["12"].id')" "foot"
check "test records the command in recent" "$(state '.recent[0] | [.kind,.exec] | join(":")')" "command:firefox -P TLA"
check "rows: command rows use the exec as subtext" "$("$WA" rows 12 | jq -r '.[] | select(.kind=="command") | .key + "|" + .subtext')" "command:firefox -P TLA|firefox -P TLA"

# --- cancel and forget --------------------------------------------------------
: > "$LOG"; rm -f "$TMP/answer"
"$WA" set; check "cancel exits 1" "$?" "1"
check "cancel launches nothing" "$(launched)" "0"
"$WA" forget "desktop:firefox"
check "forget drops from recent" "$(state '.recent | map(.id // .exec) | index("firefox")')" "null"
check "forget drops from previous" "$(state '.previous["12"] | length')" "0"
"$WA" forget "desktop:foot"
check "forget never touches defaults" "$(state '.defaults["12"].id')" "foot"

# --- launch with a stale default that was forgotten still works --------------
: > "$LOG"; CLIENTS=$CLIENTS_SAVE
CURSOR='{"x":100,"y":100}'   # DP-1, ws 21, no default
echo '{"action":"set","row":{"kind":"command","exec":"foot -e btop","label":"foot -e btop"}}' > "$TMP/answer"
"$WA" launch
check "other workspace keeps its own default" "$(state '.defaults | keys | join(",")')" "12,21"
check "command default launches via exec" "$(grep -c "dispatch exec foot -e btop" "$LOG")" "1"

# --- rows cap ----------------------------------------------------------------
reset
for i in $(seq 1 60); do
  jq -nc --arg i "$i" '{kind:"command",exec:("cmd" + $i),label:("cmd" + $i)}' > "$TMP/e"
  "$WA" run "" "$(cat "$TMP/e")" >/dev/null 2>&1
done
: > "$LOG"
for i in $(seq 1 60); do
  echo "{\"action\":\"test\",\"row\":{\"kind\":\"command\",\"exec\":\"cmd$i\",\"label\":\"cmd$i\"}}" > "$TMP/answer"
  "$WA" set >/dev/null
done
check "recent is capped at 50" "$(state '.recent | length')" "50"
check "recent keeps the newest" "$(state '.recent[0].exec')" "cmd60"

echo
if (( FAILS == 0 )); then echo "all tests passed"; else echo "$FAILS test(s) failed"; exit 1; fi
