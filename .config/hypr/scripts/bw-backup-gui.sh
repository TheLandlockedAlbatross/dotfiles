#!/usr/bin/env bash
# Copy Bitwarden GUI data.json as a timestamped backup

BACKUP_DIR="$HOME/.local/share/bitwarden-backup"
DATA_JSON="$HOME/.config/Bitwarden/data.json"

gum style --bold --border rounded --padding "0 2" --border-foreground 4 \
  "Bitwarden GUI Vault Backup"

if [[ ! -f "$DATA_JSON" ]]; then
  gum style --foreground 1 "Error: $DATA_JSON not found. Is the Bitwarden GUI installed?"
  gum confirm "Close?" --default=yes --affirmative="OK" --negative="" || true
  exit 1
fi

if ! pgrep -f Bitwarden &>/dev/null; then
  gum style --foreground 3 "Warning: Bitwarden GUI is not running. Data may be stale."
fi

# Extract account emails from data.json
mapfile -t emails < <(jq -r '.global_account_accounts | to_entries[].value.email' "$DATA_JSON" 2>/dev/null)

timestamp="$(date +%Y%m%d)_$(date +%s)"
saved=0

for email in "${emails[@]}"; do
  [[ -z "$email" || "$email" == "null" ]] && continue
  dest="$BACKUP_DIR/$email"
  mkdir -p "$dest"
  outfile="$dest/bw-gui_${timestamp}.json"
  if cp "$DATA_JSON" "$outfile"; then
    size=$(du -h "$outfile" | cut -f1)
    gum style --foreground 2 --bold "Backup saved ($size):" "$outfile"
    ((saved++))
  else
    gum style --foreground 1 "Copy failed for $email."
  fi
done

if [[ $saved -eq 0 ]]; then
  # Couldn't determine accounts — fall back to generic folder
  mkdir -p "$BACKUP_DIR/gui-unknown"
  outfile="$BACKUP_DIR/gui-unknown/bw-gui_${timestamp}.json"
  if cp "$DATA_JSON" "$outfile"; then
    size=$(du -h "$outfile" | cut -f1)
    gum style --foreground 2 --bold "Backup saved ($size):" "$outfile"
  else
    gum style --foreground 1 "Copy failed."
  fi
fi

gum confirm "Close?" --default=yes --affirmative="OK" --negative="" || true
