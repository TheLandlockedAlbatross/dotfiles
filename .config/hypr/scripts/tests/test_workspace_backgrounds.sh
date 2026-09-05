#!/bin/bash
# Tests for workspace-backgrounds.sh: what the toggle discards, and the lock /
# paint-arrangement pair the layout editor leans on.
# Everything runs against a throwaway HOME and BG_TMP, with the commands that
# touch the session stubbed on PATH. No live wallpaper is harmed.
# Run: bash tests/test_workspace_backgrounds.sh

set -u
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export BG_TMP="$TMP/tmp"
mkdir -p "$BG_TMP" "$HOME/.config/omarchy/current/theme/backgrounds" \
         "$HOME/.config/omarchy/background-layouts/images"
echo "ethereal" > "$HOME/.config/omarchy/current/theme.name"
for n in 00 01; do
  printf 'not really a jpeg\n' > "$HOME/.config/omarchy/current/theme/backgrounds/$n.jpg"
done

STATE_FILE="$HOME/.local/state/omarchy/toggles/workspace-backgrounds"
LAYOUT_DIR="$HOME/.config/omarchy/background-layouts/images"
EXTRA_FILE="$BG_TMP/hypr-bg-extra-images"
ARRANGE_FILE="$BG_TMP/hypr-bg-arrangement"
LOCK_MARK="$BG_TMP/hypr-bg-locked"
CACHE_FILE="$BG_TMP/hypr-workspace-bg-map"

# --- stubs ---------------------------------------------------------------
mkdir -p "$TMP/bin"
for cmd in pkill uwsm-app awww notify-send swayosd-client python3 logger; do
  cat > "$TMP/bin/$cmd" <<STUB
#!/bin/bash
echo "$cmd \$*" >> "$TMP/calls.log"
STUB
done
# setsid must not actually spawn the listener
cat > "$TMP/bin/setsid" <<STUB
#!/bin/bash
echo "setsid \$*" >> "$TMP/calls.log"
STUB
cat > "$TMP/bin/hyprctl" <<'STUB'
#!/bin/bash
echo '[{"name":"DP-1","disabled":false,"refreshRate":143.9,"activeWorkspace":{"id":1}},
       {"name":"DP-2","disabled":false,"refreshRate":143.9,"activeWorkspace":{"id":2}}]'
STUB
# The menu answer for the discard prompt, read from a file the tests rewrite.
cat > "$TMP/bin/omarchy-menu-select" <<STUB
#!/bin/bash
echo "menu \$*" >> "$TMP/calls.log"
cat "$TMP/menu-answer" 2>/dev/null
STUB
chmod +x "$TMP"/bin/*
PATH="$TMP/bin:$PATH"

WSB="$SCRIPTS_DIR/workspace-backgrounds.sh"
FAILS=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1: $2"; FAILS=$((FAILS+1)); }
check(){ if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "want '$3', got '$2'"; fi; }

reset_state() {
  rm -rf "$TMP/calls.log" "${LAYOUT_DIR:?}"/* "$EXTRA_FILE" "$ARRANGE_FILE" \
         "$LOCK_MARK" "$CACHE_FILE" "$STATE_FILE" "$BG_TMP/hypr-bg-layout"
  mkdir -p "$(dirname "$STATE_FILE")"
  : > "$TMP/calls.log"
}
customize() {  # two layout sidecars and one added image
  printf '{}\n' > "$LAYOUT_DIR/a.deadbeef0001.json"
  printf '{}\n' > "$LAYOUT_DIR/b.deadbeef0002.json"
  printf '%s\n' "$TMP/mine.jpg" > "$EXTRA_FILE"
}
count_sidecars() { find "$LAYOUT_DIR" -name '*.json' | wc -l; }

# --- enabling from a clean theme -----------------------------------------
reset_state
"$WSB" toggle
check "clean enable creates the toggle state" "$([[ -f $STATE_FILE ]] && echo yes || echo no)" "yes"
check "clean enable asks nothing" "$(grep -c '^menu ' "$TMP/calls.log")" "0"

# --- enabling over customizations, discard confirmed ---------------------
reset_state
customize
echo "Discard" > "$TMP/menu-answer"
"$WSB" toggle
check "discard: warned first"        "$(grep -c '^menu ' "$TMP/calls.log")" "1"
check "discard: sidecars gone"       "$(count_sidecars)" "0"
check "discard: extras gone"         "$([[ -e $EXTRA_FILE ]] && echo yes || echo no)" "no"
check "discard: feature enabled"     "$([[ -f $STATE_FILE ]] && echo yes || echo no)" "yes"
grep -q 'discarded' "$TMP/calls.log" \
  && ok "discard: notification says so" \
  || bad "discard: notification says so" "$(grep '^notify-send' "$TMP/calls.log")"

# --- enabling over customizations, discard declined ----------------------
reset_state
customize
echo "Keep, leave backgrounds as they are" > "$TMP/menu-answer"
"$WSB" toggle
check "keep: sidecars survive"    "$(count_sidecars)" "2"
check "keep: extras survive"      "$([[ -e $EXTRA_FILE ]] && echo yes || echo no)" "yes"
check "keep: feature stays off"   "$([[ -f $STATE_FILE ]] && echo yes || echo no)" "no"
check "keep: nothing was started" "$(grep -c 'awww-daemon' "$TMP/calls.log")" "0"

# --- lock: freeze what is on screen --------------------------------------
reset_state
touch "$STATE_FILE" "$CACHE_FILE"
"$WSB" lock
check "lock: marker written"      "$([[ -f $LOCK_MARK ]] && echo yes || echo no)" "yes"
check "lock: toggle state gone"   "$([[ -f $STATE_FILE ]] && echo yes || echo no)" "no"
check "lock: ws map gone"         "$([[ -f $CACHE_FILE ]] && echo yes || echo no)" "no"
check "lock: awww left running"   "$(grep -c 'awww-daemon' "$TMP/calls.log")" "0"
# The listener stays: locked or not, displays still come and go.
check "lock: listener restarted"  "$(grep -c 'setsid .*listen' "$TMP/calls.log")" "1"

# --- paint-arrangement: repaint the frozen layout ------------------------
reset_state
printf 'DP-1\t%s\nDP-2\t%s\n' "$TMP/one.jpg" "$TMP/two.jpg" > "$ARRANGE_FILE"
touch "$TMP/one.jpg" "$TMP/two.jpg"
"$WSB" paint-arrangement
check "arrangement: DP-1 painted" \
  "$(grep -c "awww img -o DP-1 $TMP/one.jpg" "$TMP/calls.log")" "1"
check "arrangement: DP-2 painted" \
  "$(grep -c "awww img -o DP-2 $TMP/two.jpg" "$TMP/calls.log")" "1"

reset_state
printf 'DP-1\t%s\n' "$TMP/gone.jpg" > "$ARRANGE_FILE"
"$WSB" paint-arrangement
check "arrangement: missing file skipped" "$(grep -c '^awww ' "$TMP/calls.log")" "0"

# --- disabling clears the locked state -----------------------------------
reset_state
touch "$STATE_FILE" "$LOCK_MARK" "$ARRANGE_FILE"
"$WSB" toggle
check "disable: lock marker gone"  "$([[ -e $LOCK_MARK ]] && echo yes || echo no)" "no"
check "disable: arrangement gone"  "$([[ -e $ARRANGE_FILE ]] && echo yes || echo no)" "no"
check "disable: swaybg restored"   "$(grep -c 'uwsm-app -- swaybg' "$TMP/calls.log")" "1"

# --- which events the listener acts on, in each mode ---------------------
# The script is sourced here, so handle_event can be called directly; the three
# things it can do are replaced with something that just says it happened.
(
  source "$WSB"
  cmd_apply_all()         { echo apply-all       >> "$TMP/did"; }
  render_layouts()        { echo render          >> "$TMP/did"; }
  cmd_paint_arrangement() { echo paint-arrangement >> "$TMP/did"; }

  did() { # <label> <event> <expected actions, space separated>
    : > "$TMP/did"
    handle_event "$2"
    check "$1" "$(tr '\n' ' ' < "$TMP/did" | sed 's/ $//')" "$3"
  }

  # Following workspaces.
  reset_state; touch "$STATE_FILE"
  did "enabled: workspace switch"   "workspacev2>>3,3"            "apply-all"
  did "enabled: focus moves"        "focusedmon>>DP-1,3"          "apply-all"
  did "enabled: workspace moved"    "moveworkspacev2>>3,3,DP-2"   "apply-all"
  did "enabled: workspace created"  "createworkspacev2>>3,3"      "apply-all"
  did "enabled: display added"      "monitoraddedv2>>4,DP-4,"     "render apply-all"
  did "enabled: display removed"    "monitorremovedv2>>4,DP-4,"   "render apply-all"
  did "enabled: v1 monitor event"   "monitoradded>>DP-4"          ""
  did "enabled: unrelated event"    "openwindow>>abc,3,foo,bar"   ""

  # Holding a locked arrangement: only the layout matters now.
  reset_state; touch "$LOCK_MARK"
  did "locked: workspace switch"    "workspacev2>>3,3"            ""
  did "locked: focus moves"         "focusedmon>>DP-1,3"          ""
  did "locked: display added"       "monitoraddedv2>>4,DP-4,"     "render paint-arrangement"
  did "locked: display removed"     "monitorremovedv2>>4,DP-4,"   "render paint-arrangement"

  # Which line of the map a workspace paints from.
  reset_state; touch "$STATE_FILE"
  seq 1 40 | sed 's#^#/theme/#; s#$#.jpg#' > "$CACHE_FILE"
  painted() { : > "$TMP/did"; cmd_apply "$1" DP-1; awk '{print $2}' "$TMP/did"; }
  bg_paint() { echo "paint $2" >> "$TMP/did"; }
  check "workspace 3 paints line 3"   "$(painted 3)"  "/theme/3.jpg"
  check "workspace 40 paints line 40" "$(painted 40)" "/theme/40.jpg"
  # Past the end of the map, wrap instead of leaving the screen black.
  check "workspace 41 wraps to line 1"  "$(painted 41)" "/theme/1.jpg"
  check "workspace 45 wraps to line 5"  "$(painted 45)" "/theme/5.jpg"
  check "workspace 80 wraps to line 40" "$(painted 80)" "/theme/40.jpg"
  check "workspace 0 paints nothing"    "$(painted 0)"  ""
  rm -f "$CACHE_FILE"

  # Off entirely.
  reset_state
  did "off: display added"          "monitoraddedv2>>4,DP-4,"     ""
  did "off: workspace switch"       "workspacev2>>3,3"            ""

  echo "$FAILS" > "$TMP/subshell-fails"
)
# A subshell that dies takes its failures with it, so insist it reported back.
if [[ -r $TMP/subshell-fails ]]; then
  FAILS=$((FAILS + $(cat "$TMP/subshell-fails")))
else
  bad "event dispatch checks" "the sourced block never finished"
fi

echo
if (( FAILS )); then echo "$FAILS FAILURE(S)"; exit 1; else echo "all workspace-backgrounds tests passed"; fi
