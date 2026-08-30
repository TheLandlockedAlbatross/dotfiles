#!/usr/bin/env bash
# Remove everything install.sh put in place. Locks sudo on the way out.
set -euo pipefail

rm -f "$HOME/Library/Application Support/Übersicht/widgets/sudo-toggle.jsx"
rm -f "$HOME/.config/sketchybar/plugins/sudo.sh"
rm -rf "$HOME/Applications/Sudo Toggle.app"

echo "Removing root script and any active rule (needs your password)..."
sudo rm -f /usr/local/sbin/sudo-toggle /etc/sudoers.d/sudo-nopasswd

command -v sketchybar >/dev/null 2>&1 && sketchybar --reload >/dev/null 2>&1 || true
echo "Done. Sudo is locked. Remove the SketchyBar item from your sketchybarrc by hand if you added it."
