#!/bin/bash
# Runs inside a WezTerm window: prompt for the login password (via sudo) and
# flip the sudo-nopasswd rule. The window closes when this exits, which relies
# on WezTerm's default exit_behavior ("Close").
clear
printf '\n  \033[1mSudo Toggle\033[0m  enter your login password to continue.\n\n'
state=$(sudo /usr/local/sbin/sudo-toggle)
rc=$?
if [ "$rc" -ne 0 ] || [ "$state" = "error" ]; then
  printf '\n  Cancelled or authentication failed; nothing changed.\n'
  osascript -e 'display notification "Cancelled; state unchanged" with title "Sudo Toggle"' >/dev/null 2>&1
elif [ "$state" = "on" ]; then
  printf '\n  \033[31mSUDO ARMED\033[0m  full passwordless root is on.\n'
  osascript -e 'display notification "Full passwordless root is now on" with title "Sudo Armed"' >/dev/null 2>&1
else
  printf '\n  \033[32mSUDO LOCKED\033[0m  root access is off.\n'
  osascript -e 'display notification "Root access is now off" with title "Sudo Locked"' >/dev/null 2>&1
fi
sleep 1.2
