#!/usr/bin/env bash
# Walker menu for Bitwarden vault backup options

choice=$(printf '  Offline Password Backup (CLI)\n  Offline Password Backup (GUI)' \
  | omarchy-launch-walker --dmenu)

case "$choice" in
  *CLI*)
    omarchy-launch-floating-terminal-with-presentation ~/.config/hypr/scripts/bw-backup-cli.sh
    ;;
  *GUI*)
    omarchy-launch-floating-terminal-with-presentation ~/.config/hypr/scripts/bw-backup-gui.sh
    ;;
esac
