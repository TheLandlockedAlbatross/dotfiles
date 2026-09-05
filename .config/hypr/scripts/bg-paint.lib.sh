# bg-paint.lib.sh — layout-aware wallpaper painting, sourced by
# workspace-backgrounds.sh and workspace-switch.sh.
#
# bg_paint <monitor> <image>
#   Looks the (image, monitor) pair up in the layout engine's index. No row or
#   missing slice -> paints the raw image exactly like before the layout
#   engine existed. A row with span members checks whether every other live
#   member's active workspace maps to the same image (span holds) and paints
#   the span or solo slice accordingly.
#
# Callers may pre-set BG_MONITORS_JSON (one `hyprctl monitors -j` snapshot)
# to avoid a refetch per call.

# Everything this side of the feature keeps lives under one directory, so a
# test run can point the whole lot somewhere harmless.
BG_TMP="${BG_TMP:-/tmp}"
BG_LAYOUT_INDEX="$BG_TMP/hypr-bg-layout/index.tsv"
BG_LAST_PAINTED="$BG_TMP/hypr-bg-layout/last-painted.tsv"
BG_LAYOUT_ENGINE="$(dirname "${BASH_SOURCE[0]}")/bg-layout.py"
BG_WS_MAP="$BG_TMP/hypr-workspace-bg-map"
# monitor<TAB>image, written by the layout editor when it locks an arrangement
# in place. Present only in that mode; see _bg_other_image.
BG_ARRANGEMENT="${BG_ARRANGEMENT:-$BG_TMP/hypr-bg-arrangement}"

# Skip the awww call when this monitor already shows this file. Returns 1 to
# skip. Keyed per monitor in a tiny tsv; cleared by do_enable.
_bg_dedupe() {
  local mon="$1" path="$2" prev
  prev=$(awk -F'\t' -v m="$mon" '$1==m {print $2; exit}' "$BG_LAST_PAINTED" 2>/dev/null)
  [[ $prev == "$path" ]] && return 1
  # Bookkeeping failures (e.g. cache dir not created yet) must never skip a
  # paint: fail open.
  mkdir -p "$(dirname "$BG_LAST_PAINTED")" 2>/dev/null
  {
    awk -F'\t' -v m="$mon" '$1!=m' "$BG_LAST_PAINTED" 2>/dev/null
    printf '%s\t%s\n' "$mon" "$path"
  } > "${BG_LAST_PAINTED}.new" 2>/dev/null &&
    mv "${BG_LAST_PAINTED}.new" "$BG_LAST_PAINTED" 2>/dev/null
  return 0
}

_bg_awww() {
  _bg_dedupe "$1" "$2" || return 0
  awww img -o "$1" "$2" --transition-type none >/dev/null 2>&1
}

# What another member of a span is showing, or nothing if it cannot break the
# span (unplugged, disabled, on a special workspace, or absent from a locked
# arrangement). A locked arrangement wins over the per-workspace map: in that
# mode the map no longer describes what is on screen.
_bg_other_image() {
  local other="$1" mons_json="$2" ws
  if [[ -r ${BG_ARRANGEMENT:-} ]]; then
    awk -F'\t' -v m="$other" '$1 == m {print $2; exit}' "$BG_ARRANGEMENT"
    return
  fi
  ws=$(jq -r --arg n "$other" \
    '.[] | select(.name == $n and .disabled == false) | .activeWorkspace.id' \
    <<<"$mons_json")
  [[ $ws =~ ^[0-9]+$ ]] || return
  sed -n "${ws}p" "$BG_WS_MAP" 2>/dev/null
}

bg_paint() {
  local mon="$1" img="$2"
  local row span solo members slice
  row=$(awk -F'\t' -v i="$img" -v m="$mon" '$1==i && $2==m {print; exit}' "$BG_LAYOUT_INDEX" 2>/dev/null)
  if [[ -z $row ]]; then
    _bg_awww "$mon" "$img"
    return
  fi
  IFS=$'\t' read -r _ _ span solo members <<<"$row"
  slice="$span"
  if [[ $members != "-" ]]; then
    local mons_json="${BG_MONITORS_JSON:-$(hyprctl monitors -j)}"
    local other other_img
    local -a others
    IFS=',' read -ra others <<<"$members"
    for other in "${others[@]}"; do
      other_img=$(_bg_other_image "$other" "$mons_json")
      if [[ -n $other_img && $other_img != "$img" ]]; then
        slice="$solo"
        break
      fi
    done
  fi
  if [[ ! -f $slice ]]; then
    # Cache wiped (or never built): degrade to the raw image and self-heal.
    _bg_awww "$mon" "$img"
    setsid python3 "$BG_LAYOUT_ENGINE" render-all >/dev/null 2>&1 </dev/null &
    return
  fi
  _bg_awww "$mon" "$slice"
}
