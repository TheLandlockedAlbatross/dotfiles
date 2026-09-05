#!/bin/bash

# Cycles to the previous background image

# v4 state paths (not the ~/.config/omarchy/current compat symlink: the
# background link resolves through ~/.local/state, and the index lookup
# below must compare identical path spellings). Filter and order match
# omarchy-theme-bg-next so next/prev walk the same list.
THEME_NAME=$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null)
THEME_BACKGROUNDS_PATH="$HOME/.local/state/omarchy/current/theme/backgrounds/"
USER_BACKGROUNDS_PATH="$HOME/.config/omarchy/backgrounds/$THEME_NAME/"
CURRENT_BACKGROUND_LINK="$HOME/.local/state/omarchy/current/background"

mapfile -d '' -t BACKGROUNDS < <(
  find -L "$USER_BACKGROUNDS_PATH" "$THEME_BACKGROUNDS_PATH" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' \) \
    -print0 2>/dev/null | sort -z
)
TOTAL=${#BACKGROUNDS[@]}

if (( TOTAL == 0 )); then
  notify-send "No background was found for theme" -t 2000
else
  if [[ -L $CURRENT_BACKGROUND_LINK ]]; then
    CURRENT_BACKGROUND=$(readlink "$CURRENT_BACKGROUND_LINK")
  else
    CURRENT_BACKGROUND=""
  fi

  INDEX=-1
  for i in "${!BACKGROUNDS[@]}"; do
    if [[ ${BACKGROUNDS[$i]} == "$CURRENT_BACKGROUND" ]]; then
      INDEX=$i
      break
    fi
  done

  if (( INDEX == -1 )); then
    NEW_BACKGROUND="${BACKGROUNDS[$((TOTAL - 1))]}"
  else
    PREV_INDEX=$(((INDEX - 1 + TOTAL) % TOTAL))
    NEW_BACKGROUND="${BACKGROUNDS[$PREV_INDEX]}"
  fi

  # v4: bg-set updates the link and notifies the shell background service;
  # the background-span watcher picks the change up for spanned swaybg slices.
  omarchy-theme-bg-set "$NEW_BACKGROUND"
fi
