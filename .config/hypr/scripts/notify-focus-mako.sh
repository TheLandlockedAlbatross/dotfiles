#!/bin/bash

# Ensure the Tier 2 auto-focus alert styling is present in the active mako
# config: a yellow border, persistent, and left-click invokes the notification's
# default action ("Go to workspace"). Omarchy regenerates the theme's mako.ini
# on every theme switch, wiping this block, so the theme-set hook re-runs this.
# Strips any existing block first, so it is safe to re-run after edits.

CFG=$(readlink -f "$HOME/.config/mako/config")
[[ -z "$CFG" || ! -w "$CFG" ]] && exit 0

# Drop any prior [category=notify-focus-alert] section (header + its keys up to
# a blank line or the next [section]).
tmp=$(mktemp)
awk '
  /^\[category=notify-focus-alert\]/ { skip=1; next }
  skip && /^\[/                      { skip=0 }
  skip && /^[[:space:]]*$/           { skip=0; next }
  !skip                              { print }
' "$CFG" > "$tmp"

cat >> "$tmp" <<'EOF'

[category=notify-focus-alert]
border-color=#f7c948
border-size=3
default-timeout=0
on-button-left=invoke-default-action
format=<b>%s</b>
width=120
padding=10,18
font=sans-serif 20px
EOF

mv "$tmp" "$CFG"
makoctl reload 2>/dev/null || true
