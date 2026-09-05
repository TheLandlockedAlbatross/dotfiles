#!/bin/bash
# Offline tests for workspace-map.sh decade resolution.
# Feeds synthetic `hyprctl monitors -j` payloads and checks the rules it plans.
# Uses a throwaway XDG_STATE_HOME so the real slot table is never touched.

MAP="$HOME/.config/hypr/scripts/workspace-map.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state"
# Belt as well as braces. The script refuses to write these when it is
# resolving against a hypothetical set of displays, but the suite must not
# depend on that being true: a build with the guard broken should fail a test,
# not repoint the rules of the machine it is running on.
export WS_MAP_CONF="$TMP/monitors.conf"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hyprctl" <<STUB
#!/bin/bash
echo "hyprctl \$*" >> "$TMP/hyprctl.log"
echo '[]'
STUB
chmod +x "$TMP/bin/hyprctl"
PATH="$TMP/bin:$PATH"

D3='AOC Q27G3G3R3 QOWP3JA001548'
D1='AOC Q27G3G3R3 QOWP3JA001705'
D2='AOC Q27G3G3R3 QOWP3JA001265'
DH='AOC Q27G3G3R3 QOWP3JA001715'

# mon <connector> <description> <x> <y> [transform] [mirrorOf] [disabled]
mon() {
  jq -nc --arg n "$1" --arg d "$2" --argjson x "$3" --argjson y "$4" \
    --argjson t "${5:-0}" --arg m "${6:-none}" --argjson dis "${7:-false}" \
    '{name:$n, description:$d, disabled:$dis, x:$x, y:$y,
      width:2560, height:1440, scale:1.25, transform:$t, mirrorOf:$m}'
}
layout() { jq -sc '.' <<<"$*"; }

M_DP3=$(mon DP-3 "$D3" 0 1152)
M_DP1=$(mon DP-1 "$D1" 0 0)
M_DP2=$(mon DP-2 "$D2" 2048 0)
M_HDMI=$(mon HDMI-A-1 "$DH" 2048 1152)

# The real rules file must come out of this suite untouched. It has not always:
# `claim` applies, and applying under a hypothetical set of displays once wrote
# rules for displays that were not plugged in.
REAL_CONF="$HOME/.config/hypr/monitors.conf"
CONF_BEFORE=$(md5sum "$REAL_CONF" 2>/dev/null | cut -d' ' -f1)

pass=0; fail=0
# check <label> <monitors-json> <ws> <expected "monitor[ default]">
check() {
  local label="$1" json="$2" ws="$3" want="$4" got
  got=$(WS_MAP_MONITORS_JSON="$json" "$MAP" plan \
    | awk -F', ' -v w="workspace = $ws" '$1 == w {
        sub(/^monitor:/, "", $2); printf "%s%s", $2, ($3 == "default:true" ? " default" : ""); exit }')
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %-34s ws %-2s want %-22s got %s\n' "$label" "$ws" "$want" "${got:-<none>}"
  fi
}

# Seed the slot table from the full layout, exactly as a first login would.
ALL=$(layout "$M_DP3 $M_DP1 $M_DP2 $M_HDMI")
WS_MAP_MONITORS_JSON="$ALL" "$MAP" plan >/dev/null
echo "=== seeded slot table ==="
cat "$XDG_STATE_HOME/hypr/workspace-map-slots"
echo

# 1. Everything connected: each panel owns its own decade and defaults to it.
check "all four" "$ALL" 1  "HDMI-A-1 default"
check "all four" "$ALL" 10 "HDMI-A-1"
check "all four" "$ALL" 11 "DP-3 default"
check "all four" "$ALL" 21 "DP-1 default"
check "all four" "$ALL" 31 "DP-2 default"

# 2. DP-3 gone: 11-20 hops to the next display clockwise, nothing else moves.
NO3=$(layout "$M_DP1 $M_DP2 $M_HDMI")
check "no DP-3" "$NO3" 1  "HDMI-A-1 default"
check "no DP-3" "$NO3" 11 "DP-1"
check "no DP-3" "$NO3" 20 "DP-1"
check "no DP-3" "$NO3" 21 "DP-1 default"
check "no DP-3" "$NO3" 31 "DP-2 default"

# 3. DP-3 and DP-1 gone: the two homeless decades split across the survivors.
NO31=$(layout "$M_DP2 $M_HDMI")
check "no DP-3/DP-1" "$NO31" 1  "HDMI-A-1 default"
check "no DP-3/DP-1" "$NO31" 11 "DP-2"
check "no DP-3/DP-1" "$NO31" 21 "HDMI-A-1"
check "no DP-3/DP-1" "$NO31" 31 "DP-2 default"

# 4. Primary gone: 1-10 hops clockwise to DP-3, the rest stay.
NOH=$(layout "$M_DP3 $M_DP1 $M_DP2")
check "no HDMI" "$NOH" 1  "DP-3"
check "no HDMI" "$NOH" 11 "DP-3 default"
check "no HDMI" "$NOH" 21 "DP-1 default"
check "no HDMI" "$NOH" 31 "DP-2 default"

# 5. Last decade's panel gone: 31-40 wraps round to slot 0.
NO2=$(layout "$M_DP3 $M_DP1 $M_HDMI")
check "no DP-2" "$NO2" 1  "HDMI-A-1 default"
check "no DP-2" "$NO2" 11 "DP-3 default"
check "no DP-2" "$NO2" 21 "DP-1 default"
check "no DP-2" "$NO2" 31 "HDMI-A-1"

# 6. One panel left: it hosts everything, and still defaults to its own decade.
ONLY_H=$(layout "$M_HDMI")
for w in 1 11 21 31; do check "only HDMI" "$ONLY_H" "$w" "HDMI-A-1$([[ $w == 1 ]] && echo ' default')"; done
ONLY_1=$(layout "$M_DP1")
for w in 1 11 21 31; do check "only DP-1" "$ONLY_1" "$w" "DP-1$([[ $w == 21 ]] && echo ' default')"; done

# 7. Cable swap: same panels, connectors exchanged. Decades follow the serial.
SWAP=$(layout "$(mon DP-1 "$D3" 0 1152) $(mon DP-3 "$D1" 0 0) $M_DP2 $M_HDMI")
check "DP-1/DP-3 cables swapped" "$SWAP" 11 "DP-1 default"
check "DP-1/DP-3 cables swapped" "$SWAP" 21 "DP-3 default"

# 8. A fifth, unknown panel with every slot taken: it owns nothing and is not
#    handed a decade, but it must not disturb the four that exist.
FIFTH=$(layout "$M_DP3 $M_DP1 $M_DP2 $M_HDMI $(mon DP-4 'Dell U2415 ABC123' 4096 0)")
check "fifth panel" "$FIFTH" 1  "HDMI-A-1 default"
check "fifth panel" "$FIFTH" 11 "DP-3 default"
check "fifth panel" "$FIFTH" 21 "DP-1 default"
check "fifth panel" "$FIFTH" 31 "DP-2 default"

# 9. Every plan must cover all 40 workspaces exactly once, whatever is plugged in.
for name in ALL NO3 NO31 NOH NO2 ONLY_H FIFTH; do
  n=$(WS_MAP_MONITORS_JSON="${!name}" "$MAP" plan | awk -F', ' '{print $1}' | sort -u | wc -l)
  if [[ $n == 40 ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL %-34s expected 40 distinct workspaces, got %s\n' "coverage/$name" "$n"
  fi
done

# 10. Exactly one default:true per connected display, on its own decade.
for name in ALL NO3 NO31 NOH NO2 ONLY_H; do
  want=$(jq 'length' <<<"${!name}")
  got=$(WS_MAP_MONITORS_JSON="${!name}" "$MAP" plan | grep -c 'default:true')
  if [[ $got == "$want" ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL %-34s expected %s defaults, got %s\n' "defaults/$name" "$want" "$got"
  fi
done

# 11. Mirrors never take a slot and never host a decade: a mirror shows a copy
#     of another panel, so a workspace parked on one would be invisible. Seeded
#     from scratch with the mirror present, which is when it could claim a slot.
MIR_STATE="$TMP/mirror"; mkdir -p "$MIR_STATE"
MIRROR=$(layout "$M_HDMI $M_DP3 $(mon DP-5 'Mirror Panel XYZ' 4096 0 0 DP-3)")
got=$(XDG_STATE_HOME="$MIR_STATE" WS_MAP_MONITORS_JSON="$MIRROR" "$MAP" plan | grep -c 'monitor:DP-5')
if [[ $got == 0 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s mirror hosts %s workspaces, want 0\n' "mirror excluded" "$got"
fi
got=$(wc -l < "$MIR_STATE/hypr/workspace-map-slots")
if [[ $got == 2 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s mirror took a slot (%s owners, want 2)\n' "mirror excluded" "$got"
fi

# A disabled output is treated exactly like an unplugged one.
DISABLED=$(layout "$M_DP1 $M_DP2 $M_HDMI $(mon DP-3 "$D3" 0 1152 0 none true)")
check "disabled = unplugged" "$DISABLED" 11 "DP-1"
check "disabled = unplugged" "$DISABLED" 21 "DP-1 default"

# 12. A rotated panel is ordered by its on-screen footprint, not by the
#     unrotated mode dimensions hyprctl keeps reporting.
#
#     A portrait panel at 0,0 is 1152 wide by 2048 tall, so its centre sits at
#     y=1024; the landscape panel beside it at x=1152 is 2048 by 1152, centre
#     y=576. Ordering starts bottom-right-most, so the portrait one wins on y.
#     Read as landscape, the portrait panel's centre drops to y=576, the two
#     tie on y, and the tie-break on x hands first place to the other panel.
#     So this layout gives opposite answers with and without the swap.
ROT_STATE="$TMP/rot"; mkdir -p "$ROT_STATE"
ROTATED=$(layout "$(mon PORTRAIT 'Panel P' 0 0 1) $(mon FLAT 'Panel F' 1152 0 0)")
got=$(XDG_STATE_HOME="$ROT_STATE" WS_MAP_MONITORS_JSON="$ROTATED" "$MAP" slots \
  | awk '/^connected:/ { print $2 }')
if [[ $got == PORTRAIT ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want PORTRAIT first, got %s\n' "rotated ordering" "$got"
fi

# 13. More displays than decades: the extras are reported, not silently dropped,
#     and the four that own decades are undisturbed.
EXTRA_STATE="$TMP/extra"; mkdir -p "$EXTRA_STATE"
SIX=$(layout "$M_DP3 $M_DP1 $M_DP2 $M_HDMI $(mon DP-6 'Extra One' 4096 0) $(mon DP-7 'Extra Two' 4096 1152)")
got=$(XDG_STATE_HOME="$EXTRA_STATE" WS_MAP_MONITORS_JSON="$SIX" "$MAP" slots | grep -c '^no decade:')
if [[ $got == 2 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want 2 undecaded displays, got %s\n' "six displays" "$got"
fi
got=$(XDG_STATE_HOME="$EXTRA_STATE" WS_MAP_MONITORS_JSON="$SIX" "$MAP" plan | awk -F', ' '{print $1}' | sort -u | wc -l)
if [[ $got == 40 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want 40 workspaces, got %s\n' "six displays coverage" "$got"
fi

# 14. DECADES is configurable: six decades means six owners and 60 workspaces.
CFG_STATE="$TMP/cfg"; mkdir -p "$CFG_STATE"
CFG_DIR="$TMP/bin"; mkdir -p "$CFG_DIR"
cp "$MAP" "$CFG_DIR/workspace-map.sh"
printf 'DECADES=6\n' > "$CFG_DIR/workspace-map.conf"
got=$(XDG_STATE_HOME="$CFG_STATE" WS_MAP_MONITORS_JSON="$SIX" "$CFG_DIR/workspace-map.sh" plan \
  | awk -F', ' '{print $1}' | sort -u | wc -l)
if [[ $got == 60 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want 60 workspaces, got %s\n' "DECADES=6 override" "$got"
fi
got=$(XDG_STATE_HOME="$CFG_STATE" WS_MAP_MONITORS_JSON="$SIX" "$CFG_DIR/workspace-map.sh" plan \
  | grep -c 'default:true')
if [[ $got == 6 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want 6 defaults, got %s\n' "DECADES=6 defaults" "$got"
fi

# 15. The slot table must survive all of the above unchanged.
if [[ $(wc -l < "$XDG_STATE_HOME/hypr/workspace-map-slots") == 4 ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL slot table changed size"; cat "$XDG_STATE_HOME/hypr/workspace-map-slots"
fi

# --- align: every display on the same position within its own decade ---------

# focus <layout-json> <connector> <workspace-id>
focus() {
  jq -c --arg n "$2" --argjson w "$3" \
    'map(.activeWorkspace = {id: (if .name == $n then $w else 1 end)}
         | .focused = (.name == $n))' <<<"$1"
}
# wsjson <"id:monitor:windows" ...>
wsjson() {
  local spec id m w out=""
  for spec in "$@"; do
    IFS=: read -r id m w <<<"$spec"
    out+=$(jq -nc --argjson i "$id" --arg m "$m" --argjson w "$w" \
      '{id:$i, monitor:$m, windows:$w}')
  done
  jq -sc '.' <<<"$out"
}
# align <label> <layout> <focused-mon> <focused-ws> <arg> <workspaces-json> <expected ws sequence>
align() {
  local label="$1" json="$2" fm="$3" fw="$4" arg="$5" wsj="$6" want="$7" got
  got=$(WS_MAP_DRY_RUN=1 WS_MAP_MONITORS_JSON="$(focus "$json" "$fm" "$fw")" \
    WS_MAP_WORKSPACES_JSON="$wsj" "$MAP" align $arg \
    | awk '$1 == "dispatch" && $2 == "workspace" {printf "%s ", $3}')
  got=${got% }
  if [[ $got == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %-34s want [%s] got [%s]\n' "$label" "$want" "$got"
  fi
}

EMPTY=$(wsjson)
# 16. Position taken from the focused workspace, focused display visited last.
align "align follows focus" "$ALL" DP-1 23 "" "$EMPTY" "3 13 33 23"
# 17. Explicit position, and 0 means the tenth slot like the digit row does.
align "align to position 7" "$ALL" DP-1 23 7 "$EMPTY" "7 17 37 27"
align "align to position 0" "$ALL" DP-1 23 0 "$EMPTY" "10 20 40 30"
# 18. A borrowed decade is not aligned: DP-3 is gone, so nothing touches 11-20
#     and its host only lines up the decade it actually owns.
align "borrowed decade skipped" "$NO3" DP-1 23 3 "$EMPTY" "3 33 23"
# 19. Focused somewhere outside the scheme (special workspace): first position.
align "focus outside the scheme" "$ALL" DP-1 -99 "" "$EMPTY" "1 11 31 21"
# 20. A display past the decade count owns nothing, so align leaves it alone.
FIVE=$(layout "$M_DP3 $M_DP1 $M_DP2 $M_HDMI $(mon DP-5 'AOC Q27G3G3R3 QOWP3JA009999' 4096 0)")
align "fifth display skipped" "$FIVE" DP-1 23 2 "$EMPTY" "2 12 32 22"

# 21. A workspace stranded on the wrong display is pulled home first.
got=$(WS_MAP_DRY_RUN=1 WS_MAP_MONITORS_JSON="$(focus "$ALL" DP-1 23)" \
  WS_MAP_WORKSPACES_JSON="$(wsjson 13:HDMI-A-1:2)" "$MAP" align 3 \
  | grep -c '^dispatch moveworkspacetomonitor 13 DP-3$')
if [[ $got == 1 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want 1 re-home of ws 13, got %s\n' "align re-homes strays" "$got"
fi

# 22. Toggle-back records the workspace we left, but only when both ends have
#     windows, matching workspace-switch.sh.
got=$(WS_MAP_DRY_RUN=1 WS_MAP_MONITORS_JSON="$(focus "$ALL" DP-1 23)" \
  WS_MAP_WORKSPACES_JSON="$(wsjson 23:DP-1:2 27:DP-1:1)" "$MAP" align 7 \
  | awk '$1 == "prev" {print $2}')
if [[ $got == 23 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want prev 23, got %s\n' "align records toggle-back" "${got:-<none>}"
fi
got=$(WS_MAP_DRY_RUN=1 WS_MAP_MONITORS_JSON="$(focus "$ALL" DP-1 23)" \
  WS_MAP_WORKSPACES_JSON="$(wsjson 23:DP-1:2 27:DP-1:0)" "$MAP" align 7 \
  | awk '$1 == "prev" {print $2}')
if [[ -z $got ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want no prev, got %s\n' "align skips empty toggle-back" "$got"
fi

# 23. Every aligned display is focused exactly once, in the dispatch order.
got=$(WS_MAP_DRY_RUN=1 WS_MAP_MONITORS_JSON="$(focus "$ALL" DP-1 23)" \
  WS_MAP_WORKSPACES_JSON="$EMPTY" "$MAP" align 4 \
  | awk '$1 == "dispatch" && $2 == "focusmonitor" {printf "%s ", $3}')
if [[ $got == "HDMI-A-1 DP-3 DP-2 DP-1 " ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s got [%s]\n' "align focus order" "$got"
fi

# 24. preview: the machine-readable version the align picker reads.
prev() { WS_MAP_MONITORS_JSON="$1" "$MAP" preview; }
got=$(prev "$ALL" | tr '\t' ' ')
want="mode decade
size 10
HDMI-A-1 1
DP-3 11
DP-1 21
DP-2 31"
if [[ $got == "$want" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s\nwant:\n%s\ngot:\n%s\n' "preview lists decade starts" "$want" "$got"
fi
# A display past the decade count owns nothing, and preview says so with "-".
got=$(prev "$FIVE" | tr '\t' ' ' | tail -1)
if [[ $got == "DP-5 -" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want "DP-5 -", got "%s"\n' "preview marks a display with no decade" "$got"
fi
# Unplugging does not hand the survivor the missing panel's decade: align only
# ever moves a display within the decade it owns.
got=$(prev "$NO3" | tr '\t' ' ' | grep -c '^DP-3')
if [[ $got == 0 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want no DP-3 row, got %s\n' "preview drops an unplugged display" "$got"
fi

# 25. claim: a replaced panel takes the decade its predecessor still holds.
CLAIM_STATE="$TMP/claim"; mkdir -p "$CLAIM_STATE"
claim_env() { XDG_STATE_HOME="$CLAIM_STATE" WS_MAP_MONITORS_JSON="$1" "$MAP" "${@:2}"; }
DZ='AOC Q27G3G3R3 QOWP3JA00ZZZZ'
M_DP3_NEW=$(mon DP-3 "$DZ" 0 1152)
REPLACED=$(layout "$M_DP3_NEW $M_DP1 $M_DP2 $M_HDMI")

claim_env "$ALL" plan >/dev/null                     # seed from the full set
got=$(claim_env "$REPLACED" slots | grep -c '^no decade')
if [[ $got == 1 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want 1 homeless display, got %s\n' "replacement starts homeless" "$got"
fi
got=$(claim_env "$REPLACED" slots | grep -c 'held by a panel that is not here')
if [[ $got == 1 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want the advisory, got %s\n' "advisory names the fixable case" "$got"
fi

claim_env "$REPLACED" claim >/dev/null 2>&1
got=$(claim_env "$REPLACED" slots | grep -c '^no decade')
if [[ $got == 0 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want none homeless after claim, got %s\n' "claim rehomes the replacement" "$got"
fi
# It takes the decade it was already showing (11-20), so nothing on screen moves.
got=$(claim_env "$REPLACED" slots | awk '/^ws 11-20/ {print $4, $5, $6}')
if [[ $got == "$DZ" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want the hosted decade, got "%s"\n' "claim takes the decade it shows" "$got"
fi

# With two decades going spare it still takes the one it is showing, and leaves
# the other with its absent owner rather than hoarding both.
TWO_STATE="$TMP/twoghosts"; mkdir -p "$TWO_STATE"
THREE=$(layout "$M_DP3_NEW $M_DP2 $M_HDMI")
two() { XDG_STATE_HOME="$TWO_STATE" WS_MAP_MONITORS_JSON="$1" "$MAP" "${@:2}"; }
XDG_STATE_HOME="$TWO_STATE" WS_MAP_MONITORS_JSON="$ALL" "$MAP" plan >/dev/null
two "$THREE" claim >/dev/null 2>&1
got=$(two "$THREE" slots | awk '/^ws 11-20/ {print $4, $5, $6}')
if [[ $got == "$DZ" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want the shown decade, got "%s"\n' "claim takes the lower spare decade" "$got"
fi
got=$(two "$THREE" slots | awk '/^ws 21-30/ {print $4, $5, $6}')
if [[ $got == "$D1" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want the absent owner kept, got "%s"\n' "claim takes only one decade" "$got"
fi
got=$(wc -l < "$CLAIM_STATE/hypr/workspace-map-slots")
if [[ $got == 4 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want 4 owners, got %s\n' "claim leaves no ghost behind" "$got"
fi
# Claiming again has nothing to do.
got=$(claim_env "$REPLACED" claim 2>&1 | grep -c .)
before=$(cat "$CLAIM_STATE/hypr/workspace-map-slots")
claim_env "$REPLACED" claim >/dev/null 2>&1
if [[ $before == "$(cat "$CLAIM_STATE/hypr/workspace-map-slots")" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s the table moved on a second claim\n' "claim is idempotent"
fi
# A display merely unplugged for a moment keeps its decade: nothing is homeless,
# so there is nothing to hand over.
before=$(cat "$CLAIM_STATE/hypr/workspace-map-slots")
claim_env "$NO3" claim >/dev/null 2>&1
if [[ $before == "$(cat "$CLAIM_STATE/hypr/workspace-map-slots")" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s an unplugged panel lost its decade\n' "claim spares a temporary unplug"
fi
# More displays than decades, every owner present: still nothing to hand over.
FIVE_STATE="$TMP/five"; mkdir -p "$FIVE_STATE"
XDG_STATE_HOME="$FIVE_STATE" WS_MAP_MONITORS_JSON="$FIVE" "$MAP" plan >/dev/null
before=$(cat "$FIVE_STATE/hypr/workspace-map-slots")
XDG_STATE_HOME="$FIVE_STATE" WS_MAP_MONITORS_JSON="$FIVE" "$MAP" claim >/dev/null 2>&1
if [[ $before == "$(cat "$FIVE_STATE/hypr/workspace-map-slots")" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s claim took a decade from a live panel\n' "claim spares live owners"
fi
got=$(XDG_STATE_HOME="$FIVE_STATE" WS_MAP_MONITORS_JSON="$FIVE" "$MAP" slots | grep -c 'beyond the 4 decades')
if [[ $got == 1 ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want the over-capacity advisory, got %s\n' "advisory tells the two cases apart" "$got"
fi

# 26. Nothing durable happens while resolving against displays you do not have.
GUARD_DIR="$TMP/guard"; mkdir -p "$GUARD_DIR/bin"
cat > "$GUARD_DIR/bin/hyprctl" <<STUB
#!/bin/bash
echo "hyprctl \$*" >> "$GUARD_DIR/hyprctl.log"
echo '[]'
STUB
chmod +x "$GUARD_DIR/bin/hyprctl"
guard_out=$(PATH="$GUARD_DIR/bin:$PATH" WS_MAP_CONF="$GUARD_DIR/monitors.conf" \
  WS_MAP_MONITORS_JSON="$ALL" "$MAP" apply 2>&1)
if [[ ! -e $GUARD_DIR/monitors.conf ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s wrote a rules file it should not have\n' "what-if apply writes no file"
fi
if [[ ! -s $GUARD_DIR/hyprctl.log ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s talked to the compositor: %s\n' "what-if apply is silent" "$(head -1 "$GUARD_DIR/hyprctl.log")"
fi
if [[ $guard_out == *"what-if"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s want a what-if note, got "%s"\n' "what-if apply says so" "$guard_out"
fi
# claim applies too, so it inherits the same guard.
: > "$GUARD_DIR/hyprctl.log"
PATH="$GUARD_DIR/bin:$PATH" WS_MAP_CONF="$GUARD_DIR/monitors.conf" \
  XDG_STATE_HOME="$CLAIM_STATE" WS_MAP_MONITORS_JSON="$REPLACED" "$MAP" claim >/dev/null 2>&1
if [[ ! -e $GUARD_DIR/monitors.conf && ! -s $GUARD_DIR/hyprctl.log ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL %-34s claim wrote through the guard\n' "what-if claim writes nothing"
fi

echo "=== sample: DP-3 and DP-1 unplugged ==="
WS_MAP_MONITORS_JSON="$NO31" "$MAP" slots

# The canary, checked last so it covers everything above.
CONF_AFTER=$(md5sum "$REAL_CONF" 2>/dev/null | cut -d' ' -f1)
if [[ $CONF_BEFORE == "$CONF_AFTER" ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf 'FAIL %-34s the suite modified %s\n' "real rules file untouched" "$REAL_CONF"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail == 0 ]]
