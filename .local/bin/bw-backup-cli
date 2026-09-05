#!/usr/bin/env bash
# Bitwarden CLI vault backup — encrypted JSON export

BACKUP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/bitwarden-backup"

gum style --bold --border rounded --padding "0 2" --border-foreground 4 \
  "Bitwarden CLI Vault Backup"

if ! command -v bw &>/dev/null; then
  gum style --foreground 1 "Error: bw CLI not found. Install it first."
  gum confirm "Close?" --default=yes --affirmative="OK" --negative="" || true
  exit 1
fi

status=$(bw status 2>/dev/null | jq -r .status)
if [[ "$status" == "unauthenticated" ]]; then
  gum style --foreground 1 "Not logged in. Run 'bw login' first."
  gum confirm "Close?" --default=yes --affirmative="OK" --negative="" || true
  exit 1
fi

password=$(gum input --password --placeholder "Master password")
if [[ -z "$password" ]]; then
  gum style --foreground 1 "No password entered."
  gum confirm "Close?" --default=yes --affirmative="OK" --negative="" || true
  exit 1
fi

export BW_MASTER_PW="$password"
session=$(bw unlock --passwordenv BW_MASTER_PW --raw 2>/dev/null)
if [[ -z "$session" ]]; then
  gum style --foreground 1 "Failed to unlock vault. Wrong password?"
  gum confirm "Close?" --default=yes --affirmative="OK" --negative="" || true
  exit 1
fi
export BW_SESSION="$session"

email=$(bw status 2>/dev/null | jq -r .userEmail)
gum style --foreground 6 "Account: $email"

gum spin --title "Syncing vault..." -- bw sync

mkdir -p "$BACKUP_DIR/$email"
timestamp="$(date +%Y%m%d)_$(date +%s)"
outfile="$BACKUP_DIR/$email/bw-export_${timestamp}.json"

# Note: bw export only accepts password as CLI arg (visible in ps briefly).
# This is a known bw CLI limitation — no --passwordenv/--passwordfile support.
if bw export --format encrypted_json --password "$password" --output "$outfile" &>/dev/null; then
  gum style --foreground 2 --bold "Backup saved:" "$outfile"
else
  gum style --foreground 1 "Export failed."
fi

unset BW_MASTER_PW
bw lock &>/dev/null
gum confirm "Close?" --default=yes --affirmative="OK" --negative="" || true
