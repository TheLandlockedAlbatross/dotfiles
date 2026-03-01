#!/bin/bash

# Cycles to the previous background image

THEME_NAME=$(cat "$HOME/.config/omarchy/current/theme.name" 2>/dev/null)
THEME_BACKGROUNDS_PATH="$HOME/.config/omarchy/current/theme/backgrounds/"
USER_BACKGROUNDS_PATH="$HOME/.config/omarchy/backgrounds/$THEME_NAME/"
CURRENT_BACKGROUND_LINK="$HOME/.config/omarchy/current/background"

mapfile -d '' -t BACKGROUNDS < <(find -L "$USER_BACKGROUNDS_PATH" "$THEME_BACKGROUNDS_PATH" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
TOTAL=${#BACKGROUNDS[@]}

if (( TOTAL == 0 )); then
  notify-send "No background was found for theme" -t 2000
  pkill -x swaybg
  setsid uwsm-app -- swaybg --color '#000000' >/dev/null 2>&1 &
else
  if [[ -L $CURRENT_BACKGROUND_LINK ]]; then
    CURRENT_BACKGROUND=$(readlink "$CURRENT_BACKGROUND_LINK")
  else
    CURRENT_BACKGROUND=""
  fi

  INDEX=-1
  for i in "${!BACKGROUNDS[@]}"; do
    if [[ ${BACKGROUNDS[$i]} == $CURRENT_BACKGROUND ]]; then
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

  ln -nsf "$NEW_BACKGROUND" "$CURRENT_BACKGROUND_LINK"

  pkill -x swaybg
  setsid uwsm-app -- swaybg -i "$CURRENT_BACKGROUND_LINK" -m fill >/dev/null 2>&1 &
fi
