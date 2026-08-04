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

# Canonical form of a key combo: fixed modifier order + uppercased key, so
# "SUPER ALT SHIFT, m" in a config file and "SUPER SHIFT ALT + M" from
# hyprctl's modmask rendering land on the same string.
canon() {
  local mods=" ${1^^} " key="${2^^}" out="" m
  # Digit-row keycodes (universal in xkb): code:10..19 = 1..9,0
  if [[ $key =~ ^CODE:1([0-9])$ ]]; then
    key=$(( (${BASH_REMATCH[1]} + 1) % 10 ))
  fi
  for m in SUPER SHIFT CTRL ALT; do
    [[ $mods == *" $m "* ]] && out+="$m "
  done
  echo "${out}+ ${key}"
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
      OFFICIAL[$(canon "$mods" "$key")]=1
    done <"$f"
  done
}

# Map every bind defined under ~/.config/hypr whose combo is NOT in the
# official set to fork (committed at HEAD in the dotfiles repo) or local
# (not committed). Last definition of a combo wins, matching Hyprland.
declare -A STATUS
build_status() {
  local f rel head_content line rest mods key combo
  for f in ~/.config/hypr/*.conf; do
    rel=".config/hypr/$(basename "$f")"
    head_content="$(git -C ~ show "HEAD:$rel" 2>/dev/null)"
    while IFS= read -r line; do
      [[ $line =~ ^[[:space:]]*bind[a-z]*[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
      rest="${BASH_REMATCH[1]}"
      mods="${rest%%,*}"
      rest="${rest#*,}"
      key="${rest%%,*}"
      key="${key//[[:space:]]/}"
      combo=$(canon "$mods" "$key")
      [[ -n ${OFFICIAL[$combo]:-} ]] && continue
      if grep -qxF "$line" <<<"$head_content"; then
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
    case "${STATUS[$(canon "$mods" "$key")]:-}" in
      fork) echo "$line" ;;
      local) echo "$line 🔴" ;;
      *) $CUSTOM_ONLY || echo "$line" ;;
    esac
  done
}

build_official
build_status
LIST="$(omarchy-menu-keybindings --print | annotate)"

if $PRINT_ONLY; then
  echo "$LIST"
  exit 0
fi

prompt="Keybindings"
$CUSTOM_ONLY && prompt="Custom keybindings"

monitor_height=$(hyprctl monitors -j | jq -r '.[] | select(.focused == true) | .height')
menu_height=$((monitor_height * 40 / 100))

echo "$LIST" | walker --dmenu -p "$prompt" --width 800 --height "$menu_height"
