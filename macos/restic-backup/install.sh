#!/usr/bin/env bash
# Install the Backup Home launcher app and the backup script.
# Entirely user-level; no sudo needed.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
apps="$HOME/Applications"
bin="$HOME/.local/bin"

echo "Installing user files..."
mkdir -p "$apps" "$bin"
install -m 755 "$here/bin/restic-backup-home" "$bin/restic-backup-home"
rm -rf "$apps/Backup Home.app"
cp -R "$here/app/Backup Home.app" "$apps/"
chmod +x "$apps/Backup Home.app/Contents/MacOS/run" \
         "$apps/Backup Home.app/Contents/Resources/backup-interactive.sh"

# Register the app so Spotlight finds it.
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$lsregister" ] && "$lsregister" -f "$apps/Backup Home.app" >/dev/null 2>&1 || true

echo
echo "Done. Trigger it from Spotlight (\"Backup Home\") or run"
echo "~/.local/bin/restic-backup-home directly. Output logs to"
echo "~/.local/state/restic-backup/last-run.log."
