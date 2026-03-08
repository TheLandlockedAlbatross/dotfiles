#!/usr/bin/env bash
# Walker menu for Bitwarden vault backup options

SCRIPT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/scripts"

choice=$(printf '  Offline Password Backup (CLI)\n  Offline Password Backup (GUI)' \
  | omarchy-launch-walker --dmenu)

case "$choice" in
  *CLI*)
    omarchy-launch-floating-terminal-with-presentation "$SCRIPT_DIR/bw-backup-cli.sh"
    ;;
  *GUI*)
    omarchy-launch-floating-terminal-with-presentation "$SCRIPT_DIR/bw-backup-gui.sh"
    ;;
esac
