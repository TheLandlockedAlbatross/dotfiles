#!/bin/bash

# Keybindings menu with provenance marks on custom (non-Omarchy) binds.
#
# Wraps `omarchy-menu-keybindings --print`, filters to custom (non-Omarchy)
# binds with --custom-only, and appends a red dot (emoji glyph, since walker's
# dmenu renders pango markup literally) to binds not yet committed to the
# dotfiles repo. Committed custom binds and official Omarchy binds are
# unmarked. (Fork/branch dot distinction tabled for now.)
#
# Usage: keybinds-menu.sh [--custom-only] [--print]
#   --custom-only   show only fork/local binds (Super+Alt+K)
#   --print, -p     print annotated list to stdout instead of opening walker

CUSTOM_ONLY=false
PRINT_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --custom-only) CUSTOM_ONLY=true ;;
    --print | -p) PRINT_ONLY=true ;;
  esac
done

# Name the modifier bits. omarchy-menu-keybindings only knows the four it
# ships with (SUPER/SHIFT/CTRL/ALT) and prints the raw modmask for anything
# else, so every Caps-layer bind shows up as "32 + 1" instead of "CAPS + 1".
# Bit 32 is Mod3, which is where input.conf's caps:hyper puts the Caps key;
# bit 2 is the real Lock modifier, dead on this setup but named for honesty.
MOD_BITS="64=SUPER|32=CAPS|1=SHIFT|4=CTRL|8=ALT|128=MOD5|16=MOD2|2=LOCK"

# Rewrite any leading numeric modmask in the rendered list back into names,
# then re-pad the column omarchy aligned to 35 before we changed its width.
demodmask() {
  awk -F' → ' -v bits="$MOD_BITS" '
    function decode(m,   p, kv, i, bit, out) {
      split(bits, p, "|")
      out = ""
      for (i = 1; i in p; i++) {
        split(p[i], kv, "=")
        bit = kv[1] + 0
        if (int(m / bit) % 2 == 1) out = out (out == "" ? "" : " ") kv[2]
      }
      return out
    }
    {
      combo = $1
      sub(/[[:space:]]+$/, "", combo)
      if (match(combo, /^[0-9]+ \+ /)) {
        names = decode(substr(combo, 1, RLENGTH - 3) + 0)
        rest = substr(combo, RLENGTH + 1)
        combo = (names == "" ? rest : names " + " rest)
      }
      printf "%-35s → %s\n", combo, $2
    }'
}

# Canonical form of a key combo: fixed modifier order + uppercased key, so
# "SUPER ALT SHIFT, m" in a config file and "SUPER SHIFT ALT + M" from
# hyprctl's modmask rendering land on the same string.
canon() {
  local mods=" ${1^^} " key="${2^^}" out="" m
  # Digit-row keycodes (universal in xkb): code:10..19 = 1..9,0
  if [[ $key =~ ^CODE:1([0-9])$ ]]; then
    key=$(( (${BASH_REMATCH[1]} + 1) % 10 ))
  fi
  # Config files spell the Caps layer MOD3; the rendered list says CAPS.
  mods="${mods//MOD3/CAPS}"
  for m in SUPER CAPS SHIFT CTRL ALT; do
    [[ $mods == *" $m "* ]] && out+="$m "
  done
  # Result lands in $CANON rather than stdout: this runs once per bind line in
  # every config file, and a command substitution per call forks a subshell
  # each time, which is most of a second on the full set.
  CANON="${out}+ ${key}"
}

# Combos defined by the official Omarchy branch. A user bind on one of these
# combos is an override of a stock bind, not a custom feature, so it stays
# classified as branch rather than flooding the custom list (e.g. re-declared
# Terminal/Workspace/Screenshot binds).
declare -A OFFICIAL
build_official() {
  local f line rest mods key
  for f in ~/.local/share/omarchy/default/hypr/bindings/*.conf ~/.local/share/omarchy/config/hypr/*.conf; do
    while IFS= read -r line; do
      [[ $line =~ ^[[:space:]]*bind[a-z]*[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
      rest="${BASH_REMATCH[1]}"
      mods="${rest%%,*}"
      rest="${rest#*,}"
      key="${rest%%,*}"
      key="${key//[[:space:]]/}"
      canon "$mods" "$key"
      OFFICIAL[$CANON]=1
    done <"$f"
  done
}

# Map every bind defined under ~/.config/hypr whose combo is NOT in the
# official set to fork (committed at HEAD in the dotfiles repo) or local
# (not committed). Last definition of a combo wins, matching Hyprland.
declare -A STATUS
build_status() {
  local f rel line rest mods key combo
  # Committed lines go into a set once per file. Grepping HEAD per bind line
  # instead costs a fork each and dominates the runtime of the whole script.
  local -A committed
  for f in ~/.config/hypr/*.conf; do
    rel=".config/hypr/${f##*/}"
    committed=()
    while IFS= read -r line; do
      [[ -n $line ]] && committed["$line"]=1
    done < <(git -C ~ show "HEAD:$rel" 2>/dev/null)
    while IFS= read -r line; do
      [[ $line =~ ^[[:space:]]*bind[a-z]*[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
      rest="${BASH_REMATCH[1]}"
      mods="${rest%%,*}"
      rest="${rest#*,}"
      key="${rest%%,*}"
      key="${key//[[:space:]]/}"
      canon "$mods" "$key"
      combo=$CANON
      [[ -n ${OFFICIAL[$combo]:-} ]] && continue
      if [[ -n ${committed["$line"]:-} ]]; then
        STATUS[$combo]="fork"
      else
        STATUS[$combo]="local"
      fi
    done <"$f"
  done
}

annotate() {
  local line combo_trim mods key
  while IFS= read -r line; do
    combo_trim="${line%%→*}"
    combo_trim="${combo_trim%"${combo_trim##*[![:space:]]}"}"
    if [[ $combo_trim == *" + "* ]]; then
      mods="${combo_trim% + *}"
      key="${combo_trim##* + }"
    else
      mods=""
      key="$combo_trim"
    fi
    canon "$mods" "$key"
    case "${STATUS[$CANON]:-}" in
      fork) echo "$line" ;;
      local) echo "$line 🔴" ;;
      *) $CUSTOM_ONLY || echo "$line" ;;
    esac
  done
}

# Provenance depends only on the config files and the committed tree, never on
# what is bound live, so it caches across presses while the list itself is
# always regenerated. Rebuilding it every time costs more than everything else
# in this script put together, and Super+K has to feel instant.
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/keybinds-menu/status"
cache_key() {
  printf '%s\n' "$(git -C ~ rev-parse HEAD 2>/dev/null)"
  stat -c '%n:%Y:%s' ~/.config/hypr/*.conf \
    ~/.local/share/omarchy/default/hypr/bindings/*.conf \
    ~/.local/share/omarchy/config/hypr/*.conf 2>/dev/null
}

KEY="$(cache_key)"
if [[ -r $CACHE.key && -r $CACHE.data && $(<"$CACHE.key") == "$KEY" ]]; then
  while IFS=$'\t' read -r combo state; do
    STATUS[$combo]="$state"
  done <"$CACHE.data"
else
  build_official
  build_status
  [[ -d ${CACHE%/*} ]] || mkdir -p "${CACHE%/*}"
  # Data first, key second: a crash in between just costs a rebuild, never a
  # stale key vouching for a half-written table.
  for combo in "${!STATUS[@]}"; do
    printf '%s\t%s\n' "$combo" "${STATUS[$combo]}"
  done >"$CACHE.data"
  printf '%s' "$KEY" >"$CACHE.key"
fi

generate() { omarchy-menu-keybindings --print | demodmask | annotate; }

if $PRINT_ONLY; then
  generate
  exit 0
fi

prompt="Keybindings"
$CUSTOM_ONLY && prompt="Custom keybindings"

monitor_height=$(hyprctl monitors -j | jq -r '.[] | select(.focused == true) | .height')
menu_height=$((monitor_height * 40 / 100))

# Piped, not collected into a variable first: walker starts up in parallel with
# the list being built instead of waiting on it.
generate | walker --dmenu -p "$prompt" --width 800 --height "$menu_height"
