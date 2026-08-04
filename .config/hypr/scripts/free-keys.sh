#!/bin/bash

# Show free keybindings by modifier or by key

BINDINGS=$(omarchy-menu-keybindings --print 2>/dev/null)

KEYS=(A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
      0 1 2 3 4 5 6 7 8 9
      F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12
      RETURN SPACE TAB ESCAPE BACKSPACE DELETE
      LEFT RIGHT UP DOWN
      COMMA SLASH minus equal PRINT
      grave apostrophe semicolon backslash
      bracketleft bracketright period)

# Display labels for keys that aren't obvious
declare -A KEY_LABEL=(
  [grave]='grave (`)'
  [apostrophe]="apostrophe (ʼ)"
  [semicolon]='semicolon (;)'
  [backslash]='backslash (\)'
  [bracketleft]='bracketleft ([)'
  [bracketright]='bracketright (])'
  [period]='period (.)'
  [minus]='minus (-)'
  [equal]='equal (=)'
  [COMMA]='COMMA (,)'
  [SLASH]='SLASH (/)'
)

MODS=(
  "SUPER"
  "SUPER SHIFT"
  "SUPER ALT"
  "SUPER CTRL"
  "SUPER SHIFT ALT"
  "SUPER SHIFT CTRL"
  "SUPER CTRL ALT"
  "SUPER SHIFT CTRL ALT"
)

label_for() {
  echo "${KEY_LABEL[$1]:-$1}"
}

key_from_label() {
  local label="$1"
  echo "${label%% (*}"
}

menu() {
  local prompt="$1"
  local options="$2"
  local extra="$3"
  echo -e "$options" | omarchy-launch-walker --dmenu --width 295 --minheight 1 --maxheight 630 -p "$prompt…" $extra 2>/dev/null
}

show_by_modifier() {
  local options=""
  for mod in "${MODS[@]}"; do
    local count=0
    for key in "${KEYS[@]}"; do
      echo "$BINDINGS" | grep -qF "$mod + $key" || ((count++))
    done
    [[ $count -gt 0 ]] && options="$options$mod ($count free)\n"
  done

  while true; do
    local choice
    choice=$(menu "Modifier" "${options%\\n}")
    [[ -z "$choice" ]] && return

    local mod="${choice% (*}"

    local free=()
    for key in "${KEYS[@]}"; do
      echo "$BINDINGS" | grep -qF "$mod + $key" || free+=("$(label_for "$key")")
    done

    local rows=""
    for ((i=0; i<${#free[@]}; i+=12)); do
      local row=""
      for ((j=i; j<i+12 && j<${#free[@]}; j++)); do
        [[ -n "$row" ]] && row="$row, "
        row="$row${free[$j]}"
      done
      [[ -n "$rows" ]] && rows="$rows\n"
      rows="$rows$row"
    done

    local result
    result=$(menu "$mod" "$rows" "--width 600")
    [[ -n "$result" ]] && exit 0
  done
}

show_by_key() {
  local options=""
  for key in "${KEYS[@]}"; do
    local count=0
    for mod in "${MODS[@]}"; do
      echo "$BINDINGS" | grep -qF "$mod + $key" || ((count++))
    done
    [[ $count -gt 0 ]] && options="$options$(label_for "$key") -> $count free\n"
  done

  while true; do
    local choice
    choice=$(menu "Key" "${options%\\n}")
    [[ -z "$choice" ]] && return

    local key
    key=$(key_from_label "${choice% ->*}")

    local combos=""
    for mod in "${MODS[@]}"; do
      echo "$BINDINGS" | grep -qF "$mod + $key" || combos="$combos$mod + $key\n"
    done

    local result
    result=$(menu "$key" "${combos%\\n}" "--width 400")
    [[ -n "$result" ]] && exit 0
  done
}

while true; do
  mode=$(menu "Free keys" "  By modifier\n  By key")
  case "$mode" in
    *modifier*) show_by_modifier ;;
    *key*) show_by_key ;;
    *) exit 0 ;;
  esac
done
