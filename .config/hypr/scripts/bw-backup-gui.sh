#!/usr/bin/env bash
# Extract per-account Bitwarden vault data from data.json as timestamped backups
# Usage: bw-backup-gui.sh [--notify|--no-notify] [--account EMAIL]
#   --notify       Send desktop notification on success (default)
#   --no-notify    Suppress desktop notifications
#   --account EMAIL  Only backup this specific account

BACKUP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/bitwarden-backup"
DATA_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/Bitwarden/data.json"
NOTIFY=1
INTERACTIVE=0
ONLY_ACCOUNT=""
[[ -t 1 ]] && INTERACTIVE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-notify) NOTIFY=0; shift ;;
    --notify)    NOTIFY=1; shift ;;
    --account)   ONLY_ACCOUNT="$2"; shift 2 ;;
    *)           shift ;;
  esac
done

msg()  { (( INTERACTIVE )) && gum style --foreground "$1" "${@:2}"; }
err()  { msg 1 "$@"; (( NOTIFY )) && notify-send -u critical "Bitwarden Backup" "$*"; }
bold() { (( INTERACTIVE )) && gum style --foreground "$1" --bold "${@:2}"; }

(( INTERACTIVE )) && gum style --bold --border rounded --padding "0 2" --border-foreground 4 \
  "Bitwarden GUI Vault Backup"

if [[ ! -f "$DATA_JSON" ]]; then
  err "$DATA_JSON not found. Is the Bitwarden GUI installed?"
  (( INTERACTIVE )) && { gum confirm "Close?" --default=yes --affirmative="OK" --negative="" || true; }
  exit 1
fi

if ! pgrep -f 'bitwarden/app\.asar' &>/dev/null; then
  msg 3 "Warning: Bitwarden GUI is not running. Data may be stale."
fi

# Build account list: uuid -> email
declare -A account_map
while IFS=$'\t' read -r uuid email; do
  [[ -z "$email" || "$email" == "null" ]] && continue
  [[ -n "$ONLY_ACCOUNT" && "$email" != "$ONLY_ACCOUNT" ]] && continue
  account_map["$uuid"]="$email"
done < <(jq -r '.global_account_accounts | to_entries[] | [.key, .value.email] | @tsv' "$DATA_JSON" 2>/dev/null)

timestamp="$(date +%Y%m%d)_$(date +%s)"
saved=0

for uuid in "${!account_map[@]}"; do
  email="${account_map[$uuid]}"
  dest="$BACKUP_DIR/$email"
  mkdir -p "$dest"
  outfile="$dest/bw-gui_${timestamp}.json"

  # Extract only this account's keys + metadata
  if jq --arg uuid "$uuid" --arg email "$email" '
    { _email: $email, _uuid: $uuid } +
    (to_entries
     | map(select(.key | startswith("user_" + $uuid + "_")))
     | from_entries)
  ' "$DATA_JSON" > "$outfile" 2>/dev/null; then
    chmod 600 "$outfile"
    size=$(du -h "$outfile" | cut -f1)
    bold 2 "Backup saved ($size):" "$outfile"
    ((saved++))
  else
    rm -f "$outfile"
    err "Extract failed for $email."
  fi
done

if (( saved > 0 && NOTIFY )); then
  notify-send -t 5000 "Bitwarden Backup" "$saved account(s) backed up"
fi

(( INTERACTIVE )) && { gum confirm "Close?" --default=yes --affirmative="OK" --negative="" || true; }
