#!/usr/bin/env bash
# Install the sudo-toggle frontends and the privileged toggle script.
# Run WITHOUT sudo; it prompts once for your password for the root parts.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
widgets="$HOME/Library/Application Support/Übersicht/widgets"
apps="$HOME/Applications"
sketchybar_plugins="$HOME/.config/sketchybar/plugins"

echo "Installing user files..."
mkdir -p "$widgets" "$apps" "$sketchybar_plugins"
cp "$here/ubersicht/sudo-toggle.jsx" "$widgets/"
cp "$here/sketchybar/sudo.sh" "$sketchybar_plugins/"
chmod +x "$sketchybar_plugins/sudo.sh"
rm -rf "$apps/Sudo Toggle.app"
cp -R "$here/app/Sudo Toggle.app" "$apps/"
chmod +x "$apps/Sudo Toggle.app/Contents/MacOS/run" \
         "$apps/Sudo Toggle.app/Contents/Resources/toggle-interactive.sh"

echo "Installing /usr/local/sbin/sudo-toggle (needs your password)..."
sudo install -d -o root -g wheel -m 755 /usr/local/sbin
sudo install -o root -g wheel -m 755 "$here/bin/sudo-toggle" /usr/local/sbin/sudo-toggle

# Register the app so Spotlight finds it; reload SketchyBar if present.
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$lsregister" ] && "$lsregister" -f "$apps/Sudo Toggle.app" >/dev/null 2>&1 || true
command -v sketchybar >/dev/null 2>&1 && sketchybar --reload >/dev/null 2>&1 || true

echo
echo "Done. Trigger it from Spotlight (\"Sudo Toggle\"), the Ubersicht widget,"
echo "or the SketchyBar pill. Default state is locked."
echo "If you use SketchyBar, see sketchybar/sketchybarrc.snippet for the item."
