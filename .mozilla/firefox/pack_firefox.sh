#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

PROFILE_FILES=(
    "prefs.js"
    "extensions.json"
    "addons.json"
    "places.sqlite"
    "favicons.sqlite"
    "search.json.mozlz4"
    "handlers.json"
    "permissions.sqlite"
    "content-prefs.sqlite"
    "storage-sync-v2.sqlite"
    "containers.json"
)

CONFIG_ITEMS=(
    "profiles.ini"
    "installs.ini"
    "Crash Reports"
)

# --- Validate profile directories ---
for profile in "${PROFILES[@]}"; do
    if [[ ! -d "$SCRIPT_DIR/$profile" ]]; then
        echo "Error: Profile directory not found: $profile"
        exit 1
    fi
done

# --- Pack profiles ---
echo "Packing profiles..."
tar_args=()
for profile in "${PROFILES[@]}"; do
    for f in "${PROFILE_FILES[@]}"; do
        filepath="$profile/$f"
        if [[ -e "$SCRIPT_DIR/$filepath" ]]; then
            tar_args+=("$filepath")
        else
            echo "  Skipping (not found): $filepath"
        fi
    done
done

if [[ ${#tar_args[@]} -eq 0 ]]; then
    echo "Error: No profile files found to pack."
    exit 1
fi

tar -cf - -C "$SCRIPT_DIR" "${tar_args[@]}" | zstd -10 -f -o "$SCRIPT_DIR/encrypted_MEO_firefox_profiles.tar.zst"
echo "Created encrypted_MEO_firefox_profiles.tar.zst"

# --- Pack config ---
echo "Packing config..."
tar_args=()
for item in "${CONFIG_ITEMS[@]}"; do
    if [[ -e "$SCRIPT_DIR/$item" ]]; then
        tar_args+=("$item")
    else
        echo "  Skipping (not found): $item"
    fi
done

if [[ ${#tar_args[@]} -eq 0 ]]; then
    echo "Error: No config files found to pack."
    exit 1
fi

tar -cf - -C "$SCRIPT_DIR" "${tar_args[@]}" | zstd -10 -f -o "$SCRIPT_DIR/encrypted_MEO_firefox_config.tar.zst"
echo "Created encrypted_MEO_firefox_config.tar.zst"

echo "Done."
