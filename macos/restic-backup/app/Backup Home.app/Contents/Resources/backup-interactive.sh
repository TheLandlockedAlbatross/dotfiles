#!/bin/bash
# Runs inside a WezTerm window: run the home backup with live progress and
# show the result. The window closes when this exits, which relies on
# WezTerm's default exit_behavior ("Close").
clear
printf '\n  \033[1mBackup Home\033[0m  backing up %s to the Malvolio repo on puck.\n\n' "$HOME"
if "$HOME/.local/bin/restic-backup-home"; then
  printf '\n  \033[32mDONE\033[0m  home backup completed.\n'
  osascript -e 'display notification "Home backup completed" with title "Backup Home"' >/dev/null 2>&1
else
  printf '\n  \033[31mFAILED\033[0m  see ~/.local/state/restic-backup/last-run.log\n'
  osascript -e 'display notification "Home backup FAILED; see last-run.log" with title "Backup Home"' >/dev/null 2>&1
fi
sleep 4
