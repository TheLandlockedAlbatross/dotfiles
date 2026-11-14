#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Extract AES-256 key from git-crypt key file
GIT_CRYPT_KEYFILE="$(git rev-parse --git-dir)/git-crypt/keys/default"
if [[ ! -r "$GIT_CRYPT_KEYFILE" ]]; then
    echo "Error: git-crypt key not found at $GIT_CRYPT_KEYFILE"
    echo "Is git-crypt unlocked in this repo?"
    exit 1
fi
AES_KEY="$(od -A n -t x1 -j 40 -N 32 "$GIT_CRYPT_KEYFILE" | tr -d ' \n')"

# Check dependencies
for cmd in tar zstd openssl; do
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

# A list entry is either a directory name in this folder or the path of a profile kept elsewhere
# (~/... or /...; the ffx agent profiles live in ~/.local/share/ffx/profiles/<name>). pack_firefox.sh
# archives an external profile under its basename, so after extraction it is moved to its real place.
profile_abs() {
    case "$1" in
        "~"|"~/"*) printf '%s\n' "${HOME}${1#\~}" ;;
        /*)        printf '%s\n' "$1" ;;
        *)         printf '%s\n' "$SCRIPT_DIR/$1" ;;
    esac
}

# --- Backup and unpack profiles ---
echo "Backing up existing profiles..."
for profile in "${PROFILES[@]}"; do
    abs="$(profile_abs "$profile")"
    if [[ -d "$abs" ]]; then
        echo "  $profile -> $(basename "$abs").bak_${TIMESTAMP}"
        mv "$abs" "${abs}.bak_${TIMESTAMP}"
    fi
done

echo "Unpacking profiles..."
openssl enc -d -aes-256-cbc -pbkdf2 -pass "pass:$AES_KEY" -in "$SCRIPT_DIR/encrypted_MEO_firefox_profiles.tar.zst" \
    | zstd -d \
    | tar -xf - -C "$SCRIPT_DIR"
for profile in "${PROFILES[@]}"; do
    abs="$(profile_abs "$profile")"
    base="$(basename "$abs")"
    if [[ "$abs" != "$SCRIPT_DIR/$base" && -d "$SCRIPT_DIR/$base" ]]; then
        mkdir -p "$(dirname "$abs")"
        mv "$SCRIPT_DIR/$base" "$abs"
        echo "  $base -> $profile"
    fi
done
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
