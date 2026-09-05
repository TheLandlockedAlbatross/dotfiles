#!/bin/bash
# Tests for bg-paint.lib.sh's span decision + fallback + dedupe logic.
# Stubs awww/hyprctl/python3/setsid via PATH; no live system touched.
# Run: bash tests/test_bg_paint.sh

set -u
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- stubs ---------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/awww" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/awww.log"
EOF
cat > "$TMP/bin/hyprctl" <<EOF
#!/bin/bash
cat "$TMP/monitors.json"
EOF
cat > "$TMP/bin/python3" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/python.log"
EOF
cat > "$TMP/bin/setsid" <<'EOF'
#!/bin/bash
exec "$@"
EOF
chmod +x "$TMP"/bin/*
PATH="$TMP/bin:$PATH"

# --- fixtures ------------------------------------------------------------
# shellcheck source=../bg-paint.lib.sh
source "$SCRIPTS_DIR/bg-paint.lib.sh"
BG_LAYOUT_INDEX="$TMP/index.tsv"
BG_LAST_PAINTED="$TMP/last-painted.tsv"
BG_WS_MAP="$TMP/ws-map"

IMG_A="/theme/00.jpg"
IMG_B="/theme/01.jpg"
SPAN_SLICE="$TMP/span.png"; touch "$SPAN_SLICE"
SOLO_SLICE="$TMP/solo.png"; touch "$SOLO_SLICE"

# DP-1 span-partnered with DP-2; DP-3 solo region; ws map: 1->A 2->B 3->A
printf '%s\tDP-1\t%s\t%s\tDP-2\n'  "$IMG_A" "$SPAN_SLICE" "$SOLO_SLICE" >  "$BG_LAYOUT_INDEX"
printf '%s\tDP-3\t%s\t%s\t-\n'     "$IMG_A" "$SPAN_SLICE" "$SPAN_SLICE" >> "$BG_LAYOUT_INDEX"
printf '%s\n%s\n%s\n' "$IMG_A" "$IMG_B" "$IMG_A" > "$BG_WS_MAP"

mons_json() { # $1 = DP-2's active ws id (or 'missing' to omit DP-2)
  if [[ $1 == missing ]]; then
    echo '[{"name":"DP-1","disabled":false,"activeWorkspace":{"id":1}}]'
  else
    echo "[{\"name\":\"DP-1\",\"disabled\":false,\"activeWorkspace\":{\"id\":1}},
          {\"name\":\"DP-2\",\"disabled\":false,\"activeWorkspace\":{\"id\":$1}}]"
  fi > "$TMP/monitors.json"
}

FAILS=0
check() { # $1 name, $2 expected-last-awww-line ('' = no call)
  local got
  got=$(tail -1 "$TMP/awww.log" 2>/dev/null || true)
  if [[ ${2:-} == "${got#img -o }" || ( -z ${2:-} && ! -s $TMP/awww.log ) ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected '${2:-<none>}', got '${got:-<none>}'"
    FAILS=$((FAILS+1))
  fi
  rm -f "$TMP/awww.log" "$BG_LAST_PAINTED"
}

# --- cases ---------------------------------------------------------------
mons_json 3
bg_paint DP-9 "$IMG_A"
check "no index row -> raw image" "DP-9 $IMG_A --transition-type none"

bg_paint DP-3 "$IMG_A"
check "solo region -> span slice" "DP-3 $SPAN_SLICE --transition-type none"

mons_json 3   # DP-2 on ws3 -> IMG_A: span holds
bg_paint DP-1 "$IMG_A"
check "span holds -> span slice" "DP-1 $SPAN_SLICE --transition-type none"

mons_json 2   # DP-2 on ws2 -> IMG_B: span broken
bg_paint DP-1 "$IMG_A"
check "span broken -> solo slice" "DP-1 $SOLO_SLICE --transition-type none"

mons_json missing   # DP-2 unplugged: span holds
bg_paint DP-1 "$IMG_A"
check "unplugged member keeps span" "DP-1 $SPAN_SLICE --transition-type none"

mons_json 99   # ws beyond map: no line -> empty -> span holds
bg_paint DP-1 "$IMG_A"
check "unmapped ws keeps span" "DP-1 $SPAN_SLICE --transition-type none"

mons_json 3
rm "$SPAN_SLICE"
bg_paint DP-1 "$IMG_A"
check "missing slice -> raw image fallback" "DP-1 $IMG_A --transition-type none"
wait  # the self-heal render-all is backgrounded
grep -q "render-all" "$TMP/python.log" && echo "ok   missing slice triggers self-heal" || {
  echo "FAIL missing slice did not trigger render-all"; FAILS=$((FAILS+1)); }
touch "$SPAN_SLICE"

mons_json 3
bg_paint DP-1 "$IMG_A"
rm -f "$TMP/awww.log"
bg_paint DP-1 "$IMG_A"   # same slice again -> dedupe, no awww call
check "repeat paint deduped" ""

BG_MONITORS_JSON=$(cat "$TMP/monitors.json") bg_paint DP-1 "$IMG_A"
check "env snapshot honored" "DP-1 $SPAN_SLICE --transition-type none"

# --- locked arrangement overrides the workspace map ----------------------
ARR="$TMP/arrangement"
BG_ARRANGEMENT="$ARR"

mons_json 2   # ws map would break the span; the arrangement says otherwise
printf 'DP-2\t%s\n' "$IMG_A" > "$ARR"
bg_paint DP-1 "$IMG_A"
check "arrangement holds span over ws map" "DP-1 $SPAN_SLICE --transition-type none"

mons_json 3   # ws map would hold the span; the arrangement breaks it
printf 'DP-2\t%s\n' "$IMG_B" > "$ARR"
bg_paint DP-1 "$IMG_A"
check "arrangement breaks span over ws map" "DP-1 $SOLO_SLICE --transition-type none"

mons_json 2   # member not listed in the arrangement cannot break the span
printf 'DP-7\t%s\n' "$IMG_B" > "$ARR"
bg_paint DP-1 "$IMG_A"
check "member absent from arrangement keeps span" "DP-1 $SPAN_SLICE --transition-type none"

rm -f "$ARR"  # gone again -> straight back to the ws map
mons_json 2
bg_paint DP-1 "$IMG_A"
check "no arrangement falls back to ws map" "DP-1 $SOLO_SLICE --transition-type none"
BG_ARRANGEMENT="/tmp/hypr-bg-arrangement"

echo
if (( FAILS )); then echo "$FAILS FAILURE(S)"; exit 1; else echo "all bg_paint tests passed"; fi
