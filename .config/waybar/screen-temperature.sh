#!/bin/bash
T=$(hyprctl hyprsunset temperature 2>/dev/null)
if [ -z "$T" ] || [ "$T" = "0" ]; then
  echo '{"text": "", "class": "hidden"}'
else
  COLOR=$(awk -v t="$T" 'BEGIN {
    t = (t < 0) ? 0 : (t > 10000) ? 10000 : t;
    # deviation from 5000K center, normalized to -1..1
    d = (t - 5000) / 5000;
    # Use sqrt for dramatic initial change that tapers off
    if (d < 0) {
      # Warm side: boost red, suppress blue/green aggressively
      strength = sqrt(-d);
      r = 255;
      g = int(255 - strength * 120);
      b = int(255 - strength * 150);
    } else {
      # Cool side: boost blue, suppress red/green aggressively
      strength = sqrt(d);
      r = int(255 - strength * 150);
      g = int(255 - strength * 120);
      b = 255;
    }
    r = (r < 100) ? 100 : r;
    g = (g < 100) ? 100 : g;
    b = (b < 100) ? 100 : b;
    printf "#%02x%02x%02x", r, g, b;
  }')
  echo "{\"text\": \"<span color='${COLOR}'>󰔏 ${T}K</span>\", \"tooltip\": \"Screen Temperature: ${T}K\"}"
fi
