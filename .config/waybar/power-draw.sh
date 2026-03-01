#!/bin/bash
profile=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)
watts_raw=$(awk '{printf "%.0f", $1 / 1000000}' /sys/class/power_supply/BAT0/power_now 2>/dev/null || echo "0")

case "$profile" in
  performance) icon="󰈸" ;;
  balanced)    icon="󰗑" ;;
  low-power)   icon="󰌪" ;;
  *)           icon="󱐋" ;;
esac

cpu_ghz=$(awk '{sum += $1; n++} END {printf "%.1f", sum / n / 1000000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A")

status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null)

# Per-core CPU usage
cpu_usage=$(awk '/^cpu[0-9]/ {
  idle = $5; total = 0;
  for (i=2; i<=NF; i++) total += $i;
  printf "CPU%d: %.0f%%\\n", n++, (1 - idle/total) * 100;
}' /proc/stat 2>/dev/null)

tooltip="${cpu_ghz}GHz\\n${cpu_usage}"

case "$status" in
  Discharging)
    # 0-7W = white, then scale to #ff8888 at 20W
    color=$(awk -v w="$watts_raw" 'BEGIN {
      if (w <= 7) {
        printf "#ffffff";
      } else {
        ratio = (w - 7) / 13;
        if (ratio > 1) ratio = 1;
        g = int(255 - ratio * (255 - 136));
        b = g;
        printf "#ff%02x%02x", g, b;
      }
    }')
    printf '{"text": "%s <span color='\''%s'\''>%sW</span>", "tooltip": "%s"}\n' "$icon" "$color" "$watts_raw" "$tooltip"
    ;;
  Charging)
    printf '{"text": "%s <span color='\''#88dd88'\''>+%sW</span>", "tooltip": "%s"}\n' "$icon" "$watts_raw" "$tooltip"
    ;;
  *)
    # Full / Not charging — no battery activity
    printf '{"text": "%s", "tooltip": "%s"}\n' "$icon" "$tooltip"
    ;;
esac
