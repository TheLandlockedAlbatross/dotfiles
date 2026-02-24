#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Check dependencies
for cmd in tar zstd; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' is not installed."
        echo "Install it with your package manager, e.g.:"
        echo "  sudo pacman -S $cmd    # Arch"
        echo "  sudo apt install $cmd  # Debian/Ubuntu"
        echo "  sudo dnf install $cmd  # Fedora"
        exit 1
    fi
done

# --- Parse arguments ---
PROFILES=()
PROFILES_FILE=""

usage() {
    echo "Usage: $(basename "$0") [--profile <name>]... [--file <path>]"
    echo "  --profile <name>   Add a profile (repeatable)"
    echo "  --file <path>      Read profiles from file (one per line)"
    echo "  If neither given, reads from encrypted_MEO_my_profiles.txt in script dir"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            [[ $# -lt 2 ]] && usage
            PROFILES+=("$2")
            shift 2
            ;;
        --file)
            [[ $# -lt 2 ]] && usage
            PROFILES_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Load profiles from file if --file was given or fall back to default
if [[ ${#PROFILES[@]} -eq 0 && -z "$PROFILES_FILE" ]]; then
    PROFILES_FILE="$SCRIPT_DIR/encrypted_MEO_my_profiles.txt"
fi

if [[ -n "$PROFILES_FILE" ]]; then
    if [[ ! -r "$PROFILES_FILE" ]]; then
        echo "Error: Cannot read profiles file: $PROFILES_FILE"
        exit 1
    fi
    while IFS= read -r line; do
        line="${line%%#*}"       # strip comments
        line="${line// /}"       # strip whitespace
        [[ -z "$line" ]] && continue
        PROFILES+=("$line")
    done < "$PROFILES_FILE"
fi

if [[ ${#PROFILES[@]} -eq 0 ]]; then
    echo "Error: No profiles specified."
    usage
fi

CONFIG_ITEMS=(
    "profiles.ini"
    "installs.ini"
    "Crash Reports"
)

# --- Validate archives exist ---
for archive in encrypted_MEO_firefox_profiles.tar.zst encrypted_MEO_firefox_config.tar.zst; do
    if [[ ! -f "$SCRIPT_DIR/$archive" ]]; then
        echo "Error: $archive not found."
        exit 1
    fi
done

# --- Backup and unpack profiles ---
echo "Backing up existing profiles..."
for profile in "${PROFILES[@]}"; do
    if [[ -d "$SCRIPT_DIR/$profile" ]]; then
        backup_name="${profile}.bak_${TIMESTAMP}"
        echo "  $profile -> $backup_name"
        mv "$SCRIPT_DIR/$profile" "$SCRIPT_DIR/$backup_name"
    fi
done

echo "Unpacking profiles..."
zstd -d "$SCRIPT_DIR/encrypted_MEO_firefox_profiles.tar.zst" --stdout | tar -xf - -C "$SCRIPT_DIR"
echo "Profiles unpacked."

# --- Backup and unpack config ---
echo "Backing up existing config..."
for item in "${CONFIG_ITEMS[@]}"; do
    if [[ -e "$SCRIPT_DIR/$item" ]]; then
        backup_name="${item}.bak_${TIMESTAMP}"
        echo "  $item -> $backup_name"
        mv "$SCRIPT_DIR/$item" "$SCRIPT_DIR/$backup_name"
    fi
done

echo "Unpacking config..."
zstd -d "$SCRIPT_DIR/encrypted_MEO_firefox_config.tar.zst" --stdout | tar -xf - -C "$SCRIPT_DIR"
echo "Config unpacked."

echo "Done. Backups are timestamped with: $TIMESTAMP"
