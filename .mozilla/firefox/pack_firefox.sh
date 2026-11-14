#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Extract AES-256 key from git-crypt key file (git-crypt can't coexist with LFS)
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
MINIMAL=false

usage() {
    echo "Usage: $(basename "$0") [--profile <name>]... [--file <path>] [--minimal]"
    echo "  --profile <name>   Add a profile (repeatable)"
    echo "  --file <path>      Read profiles from file (one per line)"
    echo "  --minimal          Pack only settings (no extensions, history, or bookmarks)"
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
        --minimal)
            MINIMAL=true
            shift
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

# Settings and about:config
PROFILE_FILES=(
    "prefs.js"
    "xulstore.json"
    "handlers.json"
    "search.json.mozlz4"
    "containers.json"
    "permissions.sqlite"
    "content-prefs.sqlite"
)

# Extension metadata and data
PROFILE_FILES_EXT=(
    "extensions.json"
    "addons.json"
    "extension-settings.json"
    "extension-preferences.json"
)

# Directories to include (full pack only)
PROFILE_DIRS=(
    "extensions"
    "browser-extension-data"
    "extension-store"
    "extension-store-menus"
    "extension-store-userscripts"
    "extension-dnr"
    "storage"
)

# History, bookmarks, extension sync storage
PROFILE_FILES_DATA=(
    "places.sqlite"
    "favicons.sqlite"
    "storage-sync-v2.sqlite"
)

# Agent profiles only (basename agent-*): the logged-in state too. The archive is encrypted twice (openssl with the git-crypt
# key, then git-crypt), so cookies, saved logins and the session can travel with the repo; the human profiles stay without them.
# sqlite -wal companions are taken when present (a running or unclean-closed Firefox keeps recent writes there).
PROFILE_FILES_AGENT=(
    "cookies.sqlite"
    "logins.json"
    "logins.db"
    "logins-backup.json"
    "key4.db"
    "cert9.db"
    "pkcs11.txt"
    "formhistory.sqlite"
    "webappsstore.sqlite"
    "sessionstore.jsonlz4"
    "sessionCheckpoints.json"
)
PROFILE_DIRS_AGENT=(
    "sessionstore-backups"
)
is_agent_profile() { [[ "$(basename "$1")" == agent-* ]]; }

# Extensions whose storage is a re-downloadable cache, left out of the pack (10ten Japanese Reader: ~420 MB dictionary
# database per profile, fetched again on first use; its settings live in storage-sync-v2.sqlite, which is packed).
STORAGE_SKIP_EXT=(
    "{59812185-ea92-4cca-8ab7-cfcacee81281}"
)
# The moz-extension UUIDs (one per line) of STORAGE_SKIP_EXT in this profile, from prefs.js extensions.webextensions.uuids.
skip_ext_uuids() {
    python3 - "$1/prefs.js" "${STORAGE_SKIP_EXT[@]}" <<'PY'
import json, re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    sys.exit(0)
m = re.search(r'user_pref\("extensions\.webextensions\.uuids", "((?:[^"\\]|\\.)*)"\);', text)
if not m:
    sys.exit(0)
uuids = json.loads(json.loads('"' + m.group(1) + '"'))
for ext in sys.argv[2:]:
    if ext in uuids:
        print(uuids[ext])
PY
}

CONFIG_ITEMS=(
    "profiles.ini"
    "installs.ini"
    "Crash Reports"
)

# A list entry is either a directory name in this folder (the human profiles) or the path of a
# profile kept elsewhere, written ~/... or /... (the ffx agent profiles live in
# ~/.local/share/ffx/profiles/<name> so that `firefox -P` never lists them). An external profile
# is archived under its basename; unpack_firefox.sh moves it back to the listed path.
profile_abs() {
    case "$1" in
        "~"|"~/"*) printf '%s\n' "${HOME}${1#\~}" ;;
        /*)        printf '%s\n' "$1" ;;
        *)         printf '%s\n' "$SCRIPT_DIR/$1" ;;
    esac
}

# --- Validate profile directories ---
for profile in "${PROFILES[@]}"; do
    if [[ ! -d "$(profile_abs "$profile")" ]]; then
        echo "Error: Profile directory not found: $profile"
        exit 1
    fi
done

# --- Build file list ---
ALL_FILES=("${PROFILE_FILES[@]}" "${PROFILE_FILES_EXT[@]}")
ALL_DIRS=()
if [[ "$MINIMAL" == false ]]; then
    ALL_FILES+=("${PROFILE_FILES_DATA[@]}")
    ALL_DIRS=("${PROFILE_DIRS[@]}")
fi

# --- Pack profiles ---
if [[ "$MINIMAL" == true ]]; then
    echo "Packing profiles (minimal — settings only)..."
else
    echo "Packing profiles (full — extensions, history, bookmarks)..."
fi
tar_args=()
n_members=0
for profile in "${PROFILES[@]}"; do
    abs="$(profile_abs "$profile")"
    base="$(basename "$abs")"
    tar_args+=(-C "$(dirname "$abs")")      # each profile is archived as <basename>/... relative to its parent
    for f in "${ALL_FILES[@]}"; do
        if [[ -e "$abs/$f" ]]; then
            tar_args+=("$base/$f"); n_members=$((n_members + 1))
        else
            echo "  Skipping (not found): $profile/$f"
        fi
    done
    for d in "${ALL_DIRS[@]}"; do
        if [[ "$d" == storage ]]; then
            # Only extension storage (userscripts, uBlock settings, ...); website data and Firefox's own caches
            # rebuild themselves, and STORAGE_SKIP_EXT extensions re-download theirs.
            skip_uuids="$(skip_ext_uuids "$abs")"
            for e in "$abs"/storage/default/moz-extension+++*; do
                [[ -d "$e" ]] || continue
                uuid="${e##*moz-extension+++}"; uuid="${uuid%%^*}"
                if [[ -n "$skip_uuids" ]] && grep -qxF "$uuid" <<<"$skip_uuids"; then continue; fi
                tar_args+=("$base/storage/default/$(basename "$e")"); n_members=$((n_members + 1))
            done
            continue
        fi
        if [[ -d "$abs/$d" ]]; then
            tar_args+=("$base/$d"); n_members=$((n_members + 1))
        else
            echo "  Skipping (not found): $profile/$d"
        fi
    done
    if [[ "$MINIMAL" == false ]] && is_agent_profile "$abs"; then
        n_agent=0
        for f in "${PROFILE_FILES_AGENT[@]}"; do
            for g in "$f" "$f-wal"; do
                if [[ -e "$abs/$g" ]]; then
                    tar_args+=("$base/$g"); n_members=$((n_members + 1)); n_agent=$((n_agent + 1))
                fi
            done
        done
        for d in "${PROFILE_DIRS_AGENT[@]}"; do
            if [[ -d "$abs/$d" ]]; then
                tar_args+=("$base/$d"); n_members=$((n_members + 1)); n_agent=$((n_agent + 1))
            fi
        done
        echo "  $profile: agent profile, logged-in state included ($n_agent items: cookies, logins, session)"
    fi
done

if [[ $n_members -eq 0 ]]; then
    echo "Error: No profile files found to pack."
    exit 1
fi

tar -cf - "${tar_args[@]}" \
    | zstd -10 \
    | openssl enc -aes-256-cbc -pbkdf2 -pass "pass:$AES_KEY" -out "$SCRIPT_DIR/encrypted_MEO_firefox_profiles.tar.zst"
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
