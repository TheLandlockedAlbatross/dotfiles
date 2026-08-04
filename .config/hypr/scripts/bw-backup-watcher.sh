#!/usr/bin/env bash
# Watch Bitwarden GUI data.json for per-account vault changes and trigger backup
# Uses inotifywait + debounced vault-key hashing to avoid noisy triggers

DATA_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/Bitwarden/data.json"
HASH_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/bitwarden-backup/.vault-hashes"
DEBOUNCE=10  # seconds to wait after last write before checking

# Hash only cipher/folder/collection IDs + revisionDates to detect
# create/edit/delete without triggering on unlock/sync noise
vault_hash_for_user() {
  local uuid="$1"
  jq --arg uuid "$uuid" '
    def revision_fingerprint:
      to_entries | map({id: .value.id, rev: .value.revisionDate}) | sort_by(.id);
    {
      ciphers:     (.["user_" + $uuid + "_ciphers_ciphers"]              // {} | revision_fingerprint),
      folders:     (.["user_" + $uuid + "_folder_folders"]               // {} | revision_fingerprint),
      collections: (.["user_" + $uuid + "_collection_collections"]       // {} | revision_fingerprint),
      sends:       (.["user_" + $uuid + "_encryptedSend_sendUserEncrypted"] // {} | revision_fingerprint)
    }
  ' "$DATA_JSON" 2>/dev/null | sha256sum | cut -d' ' -f1
}

get_accounts() {
  jq -r '.global_account_accounts | to_entries[] | [.key, .value.email] | @tsv' "$DATA_JSON" 2>/dev/null
}

mkdir -p "$HASH_DIR"

# Seed hashes for all accounts
while IFS=$'\t' read -r uuid email; do
  [[ -z "$email" || "$email" == "null" ]] && continue
  hash_file="$HASH_DIR/$uuid"
  if [[ ! -f "$hash_file" ]]; then
    vault_hash_for_user "$uuid" > "$hash_file"
  fi
done < <(get_accounts)

while true; do
  # Wait for file to exist before watching
  while [[ ! -f "$DATA_JSON" ]]; do
    sleep 5
  done

  inotifywait -qq -e close_write "$DATA_JSON" 2>/dev/null || { sleep 5; continue; }

  # Debounce: wait for writes to settle
  while inotifywait -qq -t "$DEBOUNCE" -e close_write "$DATA_JSON" 2>/dev/null; do
    :
  done

  # Check each account for changes
  while IFS=$'\t' read -r uuid email; do
    [[ -z "$email" || "$email" == "null" ]] && continue
    hash_file="$HASH_DIR/$uuid"
    last_hash=""
    [[ -f "$hash_file" ]] && last_hash=$(<"$hash_file")

    current_hash=$(vault_hash_for_user "$uuid")
    if [[ "$current_hash" != "$last_hash" ]]; then
      "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/scripts/bw-backup-gui.sh" --account "$email" "$@"
      echo "$current_hash" > "$hash_file"
    fi
  done < <(get_accounts)
done
