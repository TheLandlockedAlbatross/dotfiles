#!/usr/bin/env bash
# Remove the installed Backup Home app and script. Leaves the repo,
# password file, excludes file, and logs alone.
set -euo pipefail

rm -rf "$HOME/Applications/Backup Home.app"
rm -f "$HOME/.local/bin/restic-backup-home"
echo "Removed. Repo, password file, excludes, and logs were left in place."
