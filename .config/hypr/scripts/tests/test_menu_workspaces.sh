#!/bin/bash
# Tests for the Workspaces entries in the omarchy menu
# (~/.config/omarchy/extensions/menu.sh): what each entry lists and what it
# runs. walker and workspace-map.sh are both stubbed, so nothing is launched
# and no workspace moves.
# Run: bash tests/test_menu_workspaces.sh
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/wsmap" <<'STUB'
#!/bin/bash
echo "wsmap $*" >> "$LOG"
case "$1" in
  slots) printf 'mode: decade\ndecades: 4 of 10 workspaces\nconnected: A B\nws  1-10  owner: X  host: A\n' ;;
  mode)  echo decade ;;
esac
STUB
chmod +x "$TMP/wsmap"
export LOG="$TMP/log"; : > "$LOG"

source "$HOME/.config/omarchy/extensions/menu.sh"
WS_MAP="$TMP/wsmap"

SELECT=""
menu() { printf '%s\t%s\n' "$1" "$2" >> "$TMP/menus"; echo "$SELECT"; }
opts_for() { awk -F'\t' -v p="$1" '$1==p {print $2; exit}' "$TMP/menus"; }
back_to() { echo "back_to $1" >> "$LOG"; }

fails=0
ck() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$3' got '$2'"; fails=$((fails+1)); fi; }

# The slot list, as the menu renders it.
: > "$TMP/menus"; SELECT="" show_workspace_align_menu
rendered=$(echo -e "$(opts_for "Align to slot")")
ck "ten slots listed" "$(grep -c 'Slot' <<<"$rendered")" "10"
ck "slot 1 spells its workspaces" "$(grep -o 'Slot 1 — .*' <<<"$rendered" | head -1)" "Slot 1 — 1, 11, 21, 31"
ck "slot 10 spells its workspaces" "$(grep -o 'Slot 10 — .*' <<<"$rendered")" "Slot 10 — 10, 20, 30, 40"
ck "no leading blank entry" "$(head -1 <<<"$rendered" | grep -c 'Slot 1 ')" "1"

# Picking one runs the align for that slot.
: > "$LOG"; SELECT="󰎣  Slot 3 — 3, 13, 23, 33" show_workspace_align_menu
ck "picking slot 3 aligns to 3" "$(grep -c 'wsmap align 3$' "$LOG")" "1"
: > "$LOG"; SELECT="󰎣  Slot 10 — 10, 20, 30, 40" show_workspace_align_menu
ck "picking slot 10 aligns to 10" "$(grep -c 'wsmap align 10$' "$LOG")" "1"

# Escaping the menu goes back rather than aligning.
: > "$LOG"; SELECT="" show_workspace_align_menu
ck "escape goes back" "$(grep -c 'back_to show_workspaces_menu' "$LOG")" "1"
ck "escape aligns nothing" "$(grep -c 'wsmap align' "$LOG")" "0"

# The parent menu's own entries.
: > "$LOG"; SELECT="󰉁  Align displays to the slot in use" show_workspaces_menu
ck "current slot runs a bare align" "$(grep -c 'wsmap align$' "$LOG")" "1"
: > "$LOG"; SELECT="󰑓  Re-seed slots from the current layout" show_workspaces_menu
ck "re-seed runs reset" "$(grep -c 'wsmap reset' "$LOG")" "1"
: > "$LOG"; SELECT="󰄰  Claim a decade for a replaced panel" show_workspaces_menu
ck "claim runs claim" "$(grep -c 'wsmap claim' "$LOG")" "1"
ck "claim does not re-seed" "$(grep -c 'wsmap reset' "$LOG")" "0"
: > "$LOG"; SELECT="󰓾  Layout: decade" show_workspaces_menu
ck "layout entry toggles" "$(grep -c 'wsmap toggle' "$LOG")" "1"

# Workspaces is reachable from the Trigger menu.
: > "$LOG"; : > "$TMP/menus"; SELECT="󰕰  Workspaces" show_trigger_menu >/dev/null 2>&1
ck "trigger menu lists Workspaces" "$(opts_for Trigger | grep -c 'Workspaces')" "1"
ck "trigger menu opened the Workspaces submenu" "$(opts_for Workspaces | grep -c 'Align displays to a slot')" "1"

echo; (( fails )) && { echo "$fails FAILURE(S)"; exit 1; } || echo "all menu tests passed"
