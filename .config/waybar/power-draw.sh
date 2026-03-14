#!/bin/bash
profile=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)
watts_raw=$(awk '{printf "%.0f", $1 / 1000000}' /sys/class/power_supply/BAT0/power_now 2>/dev/null || echo "0")

case "$profile" in
  performance) icon="󰈸" ;;
  balanced)    icon="󰗑" ;;
  quiet)       icon="󰌪" ;;
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

# System power draw (PPT) from amdgpu hwmon
get_system_watts() {
  for d in /sys/class/hwmon/hwmon*; do
    if [[ $(cat "$d/name" 2>/dev/null) == "amdgpu" ]]; then
      awk '{printf "%.0f", $1 / 1000000}' "$d/power1_input" 2>/dev/null
      return
    fi
  done
  echo "0"
}

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
    # Not charging / equilibrium — show system draw from AC
    # Grey below 30W, log-scale towards red above 30W
    sys_watts=$(get_system_watts)
    ac_color=$(awk -v w="$sys_watts" 'BEGIN {
      if (w <= 30) {
        printf "#888888"
      } else {
        d = w - 30
        t = log(1 + d) / log(71)
        r = 136 + t * (255 - 136)
        g = 136 - t * (136 - 88)
        b = 136 - t * (136 - 88)
        printf "#%02x%02x%02x", r, g, b
      }
    }')
    printf '{"text": "%s <span color='\''%s'\''>~%sW</span>", "tooltip": "System draw (AC)\\n%s"}\n' "$icon" "$ac_color" "$sys_watts" "$tooltip"
    ;;
esac
