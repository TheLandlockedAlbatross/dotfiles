#!/bin/bash
# Offline tests for workspace-map.sh decade resolution.
# Feeds synthetic `hyprctl monitors -j` payloads and checks the rules it plans.
# Uses a throwaway XDG_STATE_HOME so the real slot table is never touched.

MAP="$HOME/.config/hypr/scripts/workspace-map.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state"

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

echo "=== sample: DP-3 and DP-1 unplugged ==="
WS_MAP_MONITORS_JSON="$NO31" "$MAP" slots

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail == 0 ]]
