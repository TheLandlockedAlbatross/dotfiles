# About
This is a collection of scripts, configuration files and assets that I want pretty much everywhere.

Hopefully a never-ending work in progress.

## Security
Sensitive files or files that are useless for anybody but me are encrypted and prepended with encrypted_MEO (for My Eyes Only).

This repo is designed so that `$HOME` itself is the git repo. To prevent accidentally tracking sensitive files, `.gitignore` ignores everything by default (`*`) and individual files and directories are allowlisted explicitly.

## Details

### Base
Built on [Omarchy](https://omarchy.com) (Arch + Hyprland). Everything below is what this repo adds or overrides on top of Omarchy defaults.

### Hyprland
- **Tight layout:** 4px inner gaps, 0 outer gaps, 1px border, subtle 2px rounding
- **Solo window cleanup:** border hidden when only one tiled window on workspace
- **Workspace toggle-back:** re-pressing Super+N on the current workspace toggles to the previous (non-empty) workspace
- **Fast key repeat:** 300 rate / 500ms delay (vs Omarchy's 40/600)
- **Idle timers:** 10min screensaver → 20min lock + DPMS off (vs Omarchy's 2.5min/5.5min)

### Scripts
| Script | Description |
|--------|-------------|
| `workspace-switch.sh` | Workspace toggle-back — tracks previous workspace, ignores empty workspace visits |
| `monitor-toggle.sh` | Enable/disable monitors via picker, persists to `monitors.conf` |
| `monitor-picker.py` | Interactive GTK3 layer-shell monitor placement with arrow keys, scaling, edge snapping |
| `monitor-configure.sh` | Reposition an already-active monitor interactively |
| `mullvad-cycle.sh` | Distance-sorted Mullvad relay cycling (auto-detects home location via ipinfo.io) |
| `mullvad-node-cycle.sh` | Cycle WireGuard nodes within current city |
| `screensaver.sh` | Smart screensaver: auto-launches on single display, shows picker on multi-monitor |
| `zfs-manager.sh` | Dual-pane TUI for ZFS pool/dataset/snapshot management |
| `bw-backup-menu.sh` | Bitwarden vault backup (CLI export or GUI data.json copy) |
| `swayosd-focused.sh` | SwayOSD wrapper that targets the focused monitor |
| `theme-bg-prev.sh` | Cycle to previous wallpaper (complements Omarchy's next-only) |

### Waybar
Replaces several default modules with custom widgets:

- **Clock** — shows day-of-year, weeks remaining, week number
- **Network** — real-time bandwidth, Mullvad VPN overlay (green=connected, red=disconnected), incognito mode toggle
- **Power draw** — wattage with color scaling, CPU frequency in tooltip
- **Screen temperature** — color-coded Kelvin display, scroll ±50K, click ±500K (snaps to nearest 500), swayosd notification
- **Screen brightness** — scroll ±1%, click ±10% (snaps to nearest 10), middle-click toggles compact/expanded layout
- **Poll rate** — configurable Waybar refresh interval (0.1s–60s)

### Omarchy Extensions
- **Menu overrides:** monitor toggle/configure, Mullvad VPN country picker with connect/disconnect, extended setup menu
- **Theme hook:** auto-toggles waybar active-workspace icon based on theme preference
- **Custom theme:** `ethereal-extended` — blue/purple space theme, color active workspace number instead of using default active icon, 12 additional backgrounds

### Keybindings (beyond Omarchy defaults)
- **Display:** Super+F1/F2 brightness, Super+Alt+F1/F2 color temperature (all with OSD)
- **Mullvad:** Super+M status, Super+Shift+M node cycle, Super+Alt+M relay cycle, Super+Ctrl+M incognito
- **Utilities:** Super+Z ZFS manager, Super+Shift+C open hypr config in tmux+nvim+claude
- **Apps:** Firefox profiles, Gemini/Grok per-profile, Signal, Obsidian, Typora, etc.
