#!/usr/bin/env bash
# ZFS Manager — dual-pane TUI for ZFS management (impala-style)

# ── Terminal control ─────────────────────────────────────────────────────────

enter_tui() { printf '\e[?1049h\e[?25l'; stty -echo -icanon min 1 time 0; }
leave_tui() { stty sane; printf '\e[?25h\e[?1049l'; }
pause_tui() { stty sane; printf '\e[?25h\e[?1049l'; }
resume_tui() { printf '\e[?1049h\e[?25l'; stty -echo -icanon min 1 time 0; }
trap leave_tui EXIT

# ── Colors ───────────────────────────────────────────────────────────────────

RST=$'\e[0m'  B=$'\e[1m'  DIM=$'\e[2m'  REV=$'\e[7m'
RED=$'\e[31m'  GRN=$'\e[32m'  YEL=$'\e[33m'  BLU=$'\e[34m'  CYN=$'\e[36m'  GRY=$'\e[90m'
export RST B DIM RED GRN YEL BLU CYN GRY

# ── State ────────────────────────────────────────────────────────────────────

FOCUS=0            # 0=pools, 1=configure
POOL_CUR=0         # cursor in pools box
CONF_CUR=0         # cursor in configure box
POOL_SCROLL=0      # scroll offset for pools
POOL_NAMES=()      # pool/dataset names (for selection)
POOL_LINES=()      # formatted display lines
CONF_ITEMS=("Pool Operations" "Dataset Operations" "Snapshot Operations" "Encryption")
STATUS_MSG=""

# ── Refresh pool data ────────────────────────────────────────────────────────

# Column widths
CW_NAME=40  # name/tree column
CW_VAL=6    # size/alloc/free/used/avail/refer
CW_FRAG=5
CW_CAP=4
CW_HEALTH=9
CW_MOUNT=30

# Truncate string to max width, append ... if cut
trunc() {
  local s="$1" max="$2"
  if (( ${#s} > max )); then
    echo "${s:0:$((max-3))}..."
  else
    echo "$s"
  fi
}

# Column header line (non-selectable, rendered as first entry)
POOL_HDR_NAME=""  # sentinel: empty name = header row
pool_column_header() {
  printf "${DIM}%-${CW_NAME}s %${CW_VAL}s %${CW_VAL}s %${CW_VAL}s %${CW_FRAG}s %${CW_CAP}s  %-${CW_HEALTH}s${RST}" \
    "NAME" "SIZE" "ALLOC" "FREE" "FRAG" "CAP%" "HEALTH"
}

ds_columns() {
  printf "  ${DIM}%${CW_VAL}s %${CW_VAL}s %${CW_VAL}s  %-${CW_MOUNT}s${RST}" \
    "USED" "AVAIL" "REFER" "MOUNTPOINT"
}

refresh_pools() {
  POOL_NAMES=()
  POOL_LINES=()
  local pools
  pools=$(zpool list -H -o name,size,alloc,free,frag,cap,health 2>/dev/null) || true
  if [[ -z "$pools" ]]; then
    POOL_NAMES+=("")
    POOL_LINES+=("${YEL}No ZFS pools found${RST}")
    return
  fi
  while IFS=$'\t' read -r name size alloc free frag cap health; do
    local hc="$GRN"
    [[ "$health" == "DEGRADED" ]] && hc="$YEL"
    [[ "$health" == "FAULTED" || "$health" == "UNAVAIL" || "$health" == "OFFLINE" ]] && hc="$RED"

    # Pool header row
    local tname; tname=$(trunc "$name" $CW_NAME)
    POOL_NAMES+=("$name")
    POOL_LINES+=("$(printf "${B}%-${CW_NAME}s${RST} %${CW_VAL}s %${CW_VAL}s %${CW_VAL}s %${CW_FRAG}s %${CW_CAP}s  ${hc}%-${CW_HEALTH}s${RST}" \
      "$tname" "$size" "$alloc" "$free" "$frag" "$cap" "$health")")

    # Build dataset tree
    local ds_list=()
    while IFS=$'\t' read -r ds used avail refer mp; do
      ds_list+=("${ds}	${used}	${avail}	${refer}	${mp}")
    done < <(zfs list -H -o name,used,avail,refer,mountpoint -r "$name" 2>/dev/null)

    local ds_count=${#ds_list[@]}
    for ((i=0; i<ds_count; i++)); do
      IFS=$'\t' read -r ds used avail refer mp <<< "${ds_list[$i]}"
      # Strip pool prefix to get relative path
      local rel="${ds#"$name"}"
      rel="${rel#/}"
      local depth=0
      if [[ -n "$rel" ]]; then
        local tmp="$rel"
        while [[ "$tmp" == */* ]]; do
          ((depth++))
          tmp="${tmp#*/}"
        done
      fi

      # Determine if this is the last sibling at its depth
      local parent="${ds%/*}"
      local is_last=1
      for ((j=i+1; j<ds_count; j++)); do
        local sibling_ds
        IFS=$'\t' read -r sibling_ds _ <<< "${ds_list[$j]}"
        local sibling_parent="${sibling_ds%/*}"
        if [[ "$sibling_parent" == "$parent" ]]; then
          is_last=0; break
        fi
      done

      # Build tree prefix
      local prefix=""
      if [[ -z "$rel" ]]; then
        # Root dataset (same name as pool)
        if (( ds_count > 1 )); then
          prefix="├── "
        else
          prefix="└── "
        fi
      else
        # Build indent from ancestors
        local ancestor="$name"
        local parts=()
        local tmp="$rel"
        while [[ "$tmp" == */* ]]; do
          parts+=("${tmp%%/*}")
          tmp="${tmp#*/}"
        done
        parts+=("$tmp")

        for ((d=0; d<depth; d++)); do
          ancestor="${ancestor}/${parts[$d]}"
          local anc_parent="${ancestor%/*}"
          local anc_has_more=0
          for ((j=i+1; j<ds_count; j++)); do
            local check_ds
            IFS=$'\t' read -r check_ds _ <<< "${ds_list[$j]}"
            local check_parent="${check_ds%/*}"
            if [[ "$check_parent" == "$anc_parent" ]]; then
              anc_has_more=1; break
            fi
          done
          if (( anc_has_more )); then
            prefix+="│   "
          else
            prefix+="    "
          fi
        done

        if (( is_last )); then
          prefix+="└── "
        else
          prefix+="├── "
        fi
      fi

      # Leaf name for children, full name for root dataset
      local label="$ds"
      [[ -n "$rel" ]] && label="${ds##*/}"

      # Calculate remaining space for label after tree prefix
      local prefix_len=${#prefix}
      local label_max=$((CW_NAME - prefix_len))
      (( label_max < 4 )) && label_max=4
      local tlabel; tlabel=$(trunc "$label" "$label_max")
      local tmp; tmp=$(trunc "$mp" $CW_MOUNT)

      # Insert column labels row before first dataset, using tree connector
      if (( i == 0 )); then
        local hdr_prefix="│"
        printf -v hdr_prefix "%-${CW_NAME}s" "$hdr_prefix"
        POOL_NAMES+=("")
        POOL_LINES+=("$(printf "${DIM}${hdr_prefix}${RST} $(ds_columns)")")
      fi

      POOL_NAMES+=("$ds")
      POOL_LINES+=("$(printf "${DIM}${prefix}${RST}%-${label_max}s ${DIM}%${CW_VAL}s %${CW_VAL}s %${CW_VAL}s  %-${CW_MOUNT}s${RST}" \
        "$tlabel" "$used" "$avail" "$refer" "$tmp")")
    done

    # Blank separator between pools
    POOL_NAMES+=("")
    POOL_LINES+=("")
  done <<< "$pools"

  # Remove trailing blank line
  if (( ${#POOL_LINES[@]} > 0 )) && [[ -z "${POOL_LINES[-1]}" ]]; then
    unset 'POOL_LINES[-1]'
    unset 'POOL_NAMES[-1]'
  fi

  # Ensure cursor is on a selectable row
  if (( ${#POOL_NAMES[@]} > 0 )) && ! pool_row_selectable "$POOL_CUR"; then
    POOL_CUR=0
    pool_cursor_move 1 2>/dev/null || POOL_CUR=0
  fi
}

# ── Drawing ──────────────────────────────────────────────────────────────────

# Move cursor: row col (1-based)
m() { printf '\e[%d;%dH' "$1" "$2"; }

# Draw horizontal line
hline() {
  local char="$1" n="$2"
  local i
  for ((i=0; i<n; i++)); do printf '%s' "$char"; done
}

# Strip ANSI escapes to get visible length
vislen() { local s; s=$(printf '%b' "$1" | sed 's/\x1b\[[0-9;]*m//g'); echo ${#s}; }

draw_box() {
  local y=$1 w=$2 h=$3 title="$4" active=$5 cursor=$6 scroll=$7 col_hdr="$8"
  shift 8
  local items=("$@")

  local bc="$GRY"
  local tc="$GRY"
  if [[ "$active" == 1 ]]; then
    bc="$GRN"
    tc="$GRN"
  fi

  local inner_w=$((w - 2))  # space between │ and │

  # Top border
  m "$y" 1
  local tlen=${#title}
  printf '%s┌─ %s%s%s %s' "$bc" "${B}${tc}" "$title" "${RST}${bc}" "$bc"
  hline '─' $((w - tlen - 5))
  printf '┐%s\e[K' "$RST"

  local content_start=$((y + 1))

  # Pinned column header row (no separator line)
  if [[ -n "$col_hdr" ]]; then
    m "$content_start" 1
    local vl; vl=$(vislen "$col_hdr")
    local pad=$((inner_w - 2 - vl))
    (( pad < 0 )) && pad=0
    printf '%s│%s  %b%*s%s│%s\e[K' "$bc" "$RST" "$col_hdr" "$pad" "" "$bc" "$RST"
    ((content_start++))
  fi

  # Scrollable content area
  local inner_h=$((y + h - 1 - content_start))
  local count=${#items[@]}

  for ((row=0; row<inner_h; row++)); do
    m $((content_start + row)) 1
    printf '%s│%s' "$bc" "$RST"  # left border

    local idx=$((scroll + row))
    if (( idx < count )); then
      local prefix
      if [[ "$active" == 1 ]] && (( idx == cursor )); then
        prefix="${CYN}▸${RST} "
      else
        prefix="  "
      fi
      local line="${items[$idx]}"
      local vl; vl=$(vislen "$prefix$line")
      local pad=$((inner_w - vl))
      (( pad < 0 )) && pad=0
      printf '%b%b%*s' "$prefix" "$line" "$pad" ""
    else
      printf '%*s' "$inner_w" ''
    fi

    printf '%s│%s\e[K' "$bc" "$RST"  # right border + clear EOL
  done

  # Bottom border
  m $((y + h - 1)) 1
  printf '%s└' "$bc"
  hline '─' $((w - 2))
  printf '┘%s\e[K' "$RST"
}

draw_screen() {
  local cols rows
  cols=$(tput cols)
  rows=$(tput lines)

  printf '\e[H'  # home cursor (no clear — overwrite in place)

  local box_w=$((cols))
  local pool_h=$(( (rows - 2) * 3 / 5 ))
  (( pool_h < 5 )) && pool_h=5
  local conf_h=$(( rows - 2 - pool_h ))
  (( conf_h < 4 )) && conf_h=4

  draw_box 1 "$box_w" "$pool_h" "Pools" $((FOCUS == 0 ? 1 : 0)) "$POOL_CUR" "$POOL_SCROLL" "$(pool_column_header)" "${POOL_LINES[@]}"
  draw_box $((1 + pool_h)) "$box_w" "$conf_h" "Configure" $((FOCUS == 1 ? 1 : 0)) "$CONF_CUR" 0 "" "${CONF_ITEMS[@]}"

  # Status + hints
  m $((rows)) 1
  if [[ -n "$STATUS_MSG" ]]; then
    printf '%b  ' "$STATUS_MSG"
  fi
  printf '%s↑↓%s navigate  %s→%s/%sEnter%s select  %sTab%s switch  %s←%s/%sEsc%s back  %sq%s quit\e[K\e[J' \
    "$CYN" "$RST" "$CYN" "$RST" "$CYN" "$RST" \
    "$CYN" "$RST" "$CYN" "$RST" "$CYN" "$RST" "$CYN" "$RST"
}

# ── Input ────────────────────────────────────────────────────────────────────

read_key() {
  local c
  IFS= read -rn1 c
  if [[ "$c" == $'\e' ]]; then
    local seq
    IFS= read -rn2 -t 0.05 seq || true
    case "$seq" in
      '[A') echo UP ;;
      '[B') echo DOWN ;;
      '[C') echo RIGHT ;;
      '[D') echo LEFT ;;
      '[Z') echo SHIFT_TAB ;;
      *)    echo ESC ;;
    esac
  elif [[ "$c" == $'\t' ]]; then
    echo TAB
  elif [[ "$c" == "" ]]; then
    echo ENTER
  elif [[ "$c" == "q" || "$c" == "Q" ]]; then
    echo QUIT
  elif [[ "$c" == $'\x03' ]]; then
    echo QUIT  # Ctrl+C
  fi
}

# ── Scrolling helpers ────────────────────────────────────────────────────────

# Check if a pool row is selectable (has a non-empty name)
pool_row_selectable() {
  local idx=$1
  (( idx >= 0 && idx < ${#POOL_NAMES[@]} )) && [[ -n "${POOL_NAMES[$idx]}" ]]
}

# Move pool cursor in direction (+1 or -1), skipping non-selectable rows
pool_cursor_move() {
  local dir=$1
  local next=$((POOL_CUR + dir))
  local count=${#POOL_LINES[@]}
  while (( next >= 0 && next < count )); do
    if pool_row_selectable "$next"; then
      POOL_CUR=$next
      return
    fi
    ((next += dir))
  done
}

adjust_pool_scroll() {
  local rows
  rows=$(tput lines)
  local pool_h=$(( (rows - 2) * 3 / 5 ))
  (( pool_h < 5 )) && pool_h=5
  local visible=$((pool_h - 3))  # subtract top border, col header, bottom border
  (( visible < 1 )) && visible=1
  if (( POOL_CUR < POOL_SCROLL )); then
    POOL_SCROLL=$POOL_CUR
  elif (( POOL_CUR >= POOL_SCROLL + visible )); then
    POOL_SCROLL=$((POOL_CUR - visible + 1))
  fi
}

# ── Submenus (pause TUI, use fzf/gum, resume) ───────────────────────────────

SUB_HINTS="${CYN}↑↓${RST} navigate  ${CYN}→${RST}/${CYN}Enter${RST} select  ${CYN}←${RST}/${CYN}Esc${RST} back"

sub_menu() {
  local hdr="$1"; shift
  printf '%s\n' "$@" | fzf --ansi --no-info --no-sort --no-multi \
    --header "${CYN}${B}${hdr}${RST}" --header-first \
    --bind 'left:abort,right:accept' \
    --layout reverse --height 100% \
    --color 'fg:-1,bg:-1,hl:6,fg+:4:bold,bg+:-1,hl+:6,pointer:4,header:-1,border:8,label:6' \
    --pointer '▸' --no-scrollbar \
    --prompt '' --no-separator \
    --border rounded --border-label-pos bottom \
    --border-label " $SUB_HINTS "
}

pick_pipe() {
  local label="$1"
  fzf --ansi --no-info --no-sort --no-multi \
    --header "${CYN}${B}${label}${RST}" --header-first \
    --bind 'left:abort,right:accept' \
    --layout reverse --height 100% \
    --color 'fg:-1,bg:-1,hl:6,fg+:4:bold,bg+:-1,hl+:6,pointer:4,header:-1,border:8,label:6' \
    --pointer '▸' --no-scrollbar \
    --prompt '' --no-separator \
    --border rounded --border-label-pos bottom \
    --border-label " $SUB_HINTS "
}

page() { echo "$1" | gum pager; }
pause() { echo; read -rn1 -p "Press any key to continue..."; }

pick_pool() {
  local pools
  pools=$(zpool list -H -o name 2>/dev/null)
  [[ -z "$pools" ]] && { STATUS_MSG="${RED}No pools found${RST}"; return 1; }
  local count; count=$(echo "$pools" | wc -l)
  if (( count == 1 )); then echo "$pools"
  else echo "$pools" | pick_pipe "Select pool"; fi
}

pick_dataset() {
  local pool="$1" datasets
  datasets=$(zfs list -H -o name -r "$pool" 2>/dev/null)
  [[ -z "$datasets" ]] && { STATUS_MSG="${RED}No datasets found${RST}"; return 1; }
  local count; count=$(echo "$datasets" | wc -l)
  if (( count == 1 )); then echo "$datasets"
  else echo "$datasets" | pick_pipe "Select dataset"; fi
}

pick_snapshot() {
  local dataset="$1" snaps
  if [[ -n "$dataset" ]]; then
    snaps=$(zfs list -H -t snapshot -o name -r "$dataset" 2>/dev/null)
  else
    snaps=$(zfs list -H -t snapshot -o name 2>/dev/null)
  fi
  [[ -z "$snaps" ]] && { STATUS_MSG="${RED}No snapshots found${RST}"; return 1; }
  local count; count=$(echo "$snaps" | wc -l)
  if (( count == 1 )); then echo "$snaps"
  else echo "$snaps" | pick_pipe "Select snapshot"; fi
}

# ── Operations ───────────────────────────────────────────────────────────────

pool_ops() {
  while true; do
    local choice
    choice=$(sub_menu "Pool Operations" \
      "List pools (verbose)" \
      "Detailed status / vdev tree" \
      "Import pool" \
      "Export pool" \
      "Start scrub" \
      "Cancel scrub" \
      "Trim" \
      "I/O stats" \
      "History" \
      "Upgrade features" \
      "Get all properties" \
      "Set property") || return
    STATUS_MSG=""
    case "$choice" in
      "List pools (verbose)")
        page "$(zpool list -v 2>&1)" ;;
      "Detailed status / vdev tree")
        local pool; pool=$(pick_pool) || continue
        page "$(zpool status -v "$pool" 2>&1)" ;;
      "Import pool")
        clear
        echo "${B}Import Pool${RST}"
        echo

        # --- Step 1: Find and offer to unlock LUKS devices ---
        local opened_luks=()
        local luks_devs
        luks_devs=$(sudo blkid -t TYPE=crypto_LUKS -o device 2>/dev/null) || true
        if [[ -n "$luks_devs" ]]; then
          # Filter to only show locked ones (not already open)
          local locked_luks=()
          while IFS= read -r dev; do
            local dm_name
            dm_name=$(lsblk -nro TYPE,NAME "$dev" 2>/dev/null | awk '$1=="crypt"{print $2}')
            if [[ -z "$dm_name" ]]; then
              locked_luks+=("$dev")
            fi
          done <<< "$luks_devs"

          if [[ ${#locked_luks[@]} -gt 0 ]]; then
            # Build display labels: /dev/sdX (LABEL) or /dev/sdX (SIZE)
            local luks_labels=()
            for d in "${locked_luks[@]}"; do
              local label; label=$(lsblk -ndo LABEL "$d" 2>/dev/null)
              [[ -z "$label" ]] && label=$(sudo blkid -s LABEL -o value "$d" 2>/dev/null)
              if [[ -n "$label" ]]; then
                luks_labels+=("$d ($label)")
              else
                local sz; sz=$(lsblk -ndo SIZE "$d" 2>/dev/null)
                luks_labels+=("$d (${sz:-unknown})")
              fi
            done

            echo "Locked LUKS devices found:"
            for lbl in "${luks_labels[@]}"; do echo "  $lbl"; done
            echo
            if gum confirm "Unlock LUKS device(s) before scanning for pools?"; then
              local pick_label
              pick_label=$(printf '%s\n' "${luks_labels[@]}" | pick_pipe "Unlock which device?") || true
              if [[ -n "$pick_label" ]]; then
                # Extract /dev/... path from label
                local pick_luks; pick_luks="${pick_label%% *}"
                # Auto-generate mapper name: label if available, else crypt-sdXN
                local luks_name
                local label; label=$(lsblk -ndo LABEL "$pick_luks" 2>/dev/null)
                [[ -z "$label" ]] && label=$(sudo blkid -s LABEL -o value "$pick_luks" 2>/dev/null)
                if [[ -n "$label" ]]; then
                  luks_name="crypt-${label// /-}"
                else
                  luks_name="crypt-$(basename "$pick_luks")"
                fi
                echo "Opening $pick_luks as /dev/mapper/$luks_name..."
                if sudo cryptsetup open "$pick_luks" "$luks_name" --type luks; then
                  echo "${GRN}LUKS device opened${RST}"
                  opened_luks+=("$luks_name")
                else
                  echo "${RED}Failed to unlock $pick_luks${RST}"
                  pause; continue
                fi
              fi
            fi
            echo
          fi
        fi

        # --- Step 2: Scan for importable ZFS pools ---
        echo "Scanning for ZFS pools..."
        local scan; scan=$(sudo zpool import 2>&1) || true
        if [[ -z "$scan" ]] || echo "$scan" | grep -q "no pools available"; then
          echo "${YEL}No pools available to import${RST}"
          # Close any LUKS devices we just opened
          for ln in "${opened_luks[@]}"; do sudo cryptsetup close "$ln" 2>/dev/null; done
          pause; STATUS_MSG="${YEL}No pools found${RST}"; continue
        fi
        page "$scan"
        local names; names=$(echo "$scan" | grep "pool:" | awk '{print $2}')
        [[ -z "$names" ]] && {
          for ln in "${opened_luks[@]}"; do sudo cryptsetup close "$ln" 2>/dev/null; done
          STATUS_MSG="${YEL}Could not parse pool names${RST}"; continue
        }
        local pick; pick=$(echo "$names" | pick_pipe "Import which pool?") || {
          for ln in "${opened_luks[@]}"; do sudo cryptsetup close "$ln" 2>/dev/null; done
          continue
        }

        # --- Step 3: Import the pool ---
        echo
        echo "Importing pool '$pick'..."
        local import_out
        import_out=$(sudo zpool import "$pick" 2>&1)
        if [[ $? -ne 0 ]]; then
          echo "${RED}Import failed:${RST}"
          echo "$import_out"
          for ln in "${opened_luks[@]}"; do sudo cryptsetup close "$ln" 2>/dev/null; done
          pause; STATUS_MSG="${RED}Failed to import '$pick'${RST}"; continue
        fi
        echo "${GRN}Pool imported${RST}"

        # --- Step 4: Load ZFS native encryption keys ---
        local enc_ds
        enc_ds=$(zfs get -H -r -o name,value keystatus "$pick" 2>/dev/null \
          | awk -F'\t' '$2 == "unavailable" {print $1}')
        if [[ -n "$enc_ds" ]]; then
          echo
          echo "Encrypted datasets found — loading keys..."
          while IFS= read -r ds; do
            local kf; kf=$(zfs get -H -o value keyformat "$ds" 2>/dev/null)
            case "$kf" in
              passphrase)
                echo "  Loading key for $ds (passphrase prompt)..."
                if ! sudo zfs load-key "$ds"; then
                  echo "  ${YEL}Warning: failed to load key for $ds${RST}"
                else
                  echo "  ${GRN}Key loaded${RST}"
                fi
                ;;
              raw|hex)
                local keyfile; keyfile=$(gum input --placeholder "Key file path for $ds")
                if [[ -n "$keyfile" && -f "$keyfile" ]]; then
                  if ! sudo zfs load-key -L "file://$keyfile" "$ds"; then
                    echo "  ${YEL}Warning: failed to load key for $ds${RST}"
                  else
                    echo "  ${GRN}Key loaded${RST}"
                  fi
                else
                  echo "  ${YEL}Skipping $ds — no key file provided${RST}"
                fi
                ;;
            esac
          done <<< "$enc_ds"
        fi

        # --- Step 5: Mount all datasets ---
        echo
        echo "Mounting datasets..."
        sudo zfs mount -a -l 2>/dev/null || true
        echo "${GRN}Done — pool '$pick' imported and mounted${RST}"
        pause
        STATUS_MSG="${GRN}Pool '$pick' imported and mounted${RST}" ;;

      "Export pool")
        local pool; pool=$(pick_pool) || continue
        gum confirm "Export pool '$pool'?" || continue

        clear
        echo "${B}Exporting pool '$pool'...${RST}"
        echo

        # Capture backing devices BEFORE export (pool gone after)
        local mapper_devs=()
        local vdevs
        vdevs=$(zpool status -LP "$pool" 2>/dev/null | awk '/\/dev\//{print $1}') || true
        if [[ -n "$vdevs" ]]; then
          for dev in $vdevs; do
            if [[ "$dev" == /dev/mapper/* ]]; then
              mapper_devs+=("$(basename "$dev")")
            elif [[ "$dev" == /dev/dm-* ]]; then
              local mname
              mname=$(sudo dmsetup info -c --noheadings -o name "$dev" 2>/dev/null) || true
              [[ -n "$mname" ]] && mapper_devs+=("$mname")
            fi
          done
        fi

        # Unmount all datasets first (deepest first) — must unmount before unloading keys
        local mounted
        mounted=$(zfs list -H -o name,mounted -r "$pool" 2>/dev/null \
          | awk -F'\t' '$2 == "yes" {print $1}' | sort -r)
        if [[ -n "$mounted" ]]; then
          echo "Unmounting datasets..."
          while IFS= read -r ds; do
            echo -n "  $ds ... "
            if sudo zfs unmount "$ds" 2>&1; then
              echo "${GRN}ok${RST}"
            else
              echo "${YEL}failed${RST}"
            fi
          done <<< "$mounted"
        fi

        # Unload all ZFS encryption keys (after unmount)
        local enc_ds
        enc_ds=$(zfs get -H -r -o name,value keystatus "$pool" 2>/dev/null \
          | awk -F'\t' '$2 == "available" {print $1}') || true
        if [[ -n "$enc_ds" ]]; then
          if gum confirm "Unload ZFS encryption keys?" --default=yes; then
            echo "Unloading encryption keys..."
            while IFS= read -r ds; do
              echo -n "  $ds ... "
              if sudo zfs unload-key "$ds" 2>&1; then
                echo "${GRN}ok${RST}"
              else
                echo "${YEL}failed (may still be in use)${RST}"
              fi
            done <<< "$enc_ds"
          else
            echo "${DIM}Skipping ZFS key unload${RST}"
          fi
        fi

        # Export
        echo -n "Exporting pool... "
        if sudo zpool export "$pool" 2>&1; then
          echo "${GRN}ok${RST}"
        else
          echo "${RED}failed${RST}"
          echo
          if gum confirm "Force export '$pool'?"; then
            echo -n "Force exporting... "
            if sudo zpool export -f "$pool" 2>&1; then
              echo "${GRN}ok${RST}"
            else
              echo "${RED}failed${RST}"
              pause; STATUS_MSG="${RED}Force export failed${RST}"; continue
            fi
          else
            pause; STATUS_MSG="${RED}Export aborted${RST}"; continue
          fi
        fi

        # Close any LUKS mapper devices that backed this pool
        for mname in "${mapper_devs[@]}"; do
          if [[ -e "/dev/mapper/$mname" ]]; then
            if gum confirm "Close LUKS device '$mname'?" --default=yes; then
              echo -n "  Closing $mname ... "
              if sudo cryptsetup close "$mname" 2>/dev/null; then
                echo "${GRN}ok${RST}"
              else
                echo "${YEL}failed${RST}"
              fi
            else
              echo "${DIM}Skipping LUKS close for $mname${RST}"
            fi
          fi
        done

        echo
        echo "${GRN}Done — pool '$pool' exported${RST}"
        pause
        STATUS_MSG="${GRN}Pool '$pool' exported${RST}" ;;
      "Start scrub")
        local pool; pool=$(pick_pool) || continue
        sudo zpool scrub "$pool" \
          && STATUS_MSG="${GRN}Scrub started on '$pool'${RST}" \
          || STATUS_MSG="${RED}Scrub failed${RST}" ;;
      "Cancel scrub")
        local pool; pool=$(pick_pool) || continue
        sudo zpool scrub -s "$pool" \
          && STATUS_MSG="${GRN}Scrub cancelled on '$pool'${RST}" \
          || STATUS_MSG="${RED}Cancel failed${RST}" ;;
      "Trim")
        local pool; pool=$(pick_pool) || continue
        gum confirm "Start TRIM on '$pool'?" || continue
        sudo zpool trim "$pool" \
          && STATUS_MSG="${GRN}TRIM started on '$pool'${RST}" \
          || STATUS_MSG="${RED}TRIM failed${RST}" ;;
      "I/O stats")
        local pool; pool=$(pick_pool) || continue
        page "$(zpool iostat -v "$pool" 5 3 2>&1)" ;;
      "History")
        local pool; pool=$(pick_pool) || continue
        page "$(sudo zpool history "$pool" 2>&1)" ;;
      "Upgrade features")
        local pool; pool=$(pick_pool) || continue
        page "$(sudo zpool upgrade -v "$pool" 2>&1)"
        gum confirm "Upgrade pool '$pool' features?" || continue
        sudo zpool upgrade "$pool" \
          && STATUS_MSG="${GRN}Upgrade complete${RST}" \
          || STATUS_MSG="${RED}Upgrade failed${RST}" ;;
      "Get all properties")
        local pool; pool=$(pick_pool) || continue
        page "$(zpool get all "$pool" 2>&1)" ;;
      "Set property")
        local pool; pool=$(pick_pool) || continue
        local prop; prop=$(gum input --placeholder "property=value (e.g. comment=mypool)")
        [[ -z "$prop" ]] && continue
        sudo zpool set "$prop" "$pool" \
          && STATUS_MSG="${GRN}Property set${RST}" \
          || STATUS_MSG="${RED}Failed to set property${RST}" ;;
    esac
  done
}

dataset_ops() {
  while true; do
    local choice
    choice=$(sub_menu "Dataset Operations" \
      "List datasets" \
      "Mount" \
      "Unmount" \
      "Create dataset" \
      "Destroy dataset" \
      "Get all properties" \
      "Set property") || return
    STATUS_MSG=""
    case "$choice" in
      "List datasets")
        page "$(zfs list 2>&1)" ;;
      "Mount")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        sudo zfs mount "$ds" \
          && STATUS_MSG="${GRN}'$ds' mounted${RST}" \
          || STATUS_MSG="${RED}Mount failed${RST}" ;;
      "Unmount")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        gum confirm "Unmount '$ds'?" || continue
        sudo zfs unmount "$ds" \
          && STATUS_MSG="${GRN}'$ds' unmounted${RST}" \
          || STATUS_MSG="${RED}Unmount failed${RST}" ;;
      "Create dataset")
        local pool; pool=$(pick_pool) || continue
        local parent; parent=$(pick_dataset "$pool") || continue
        local name; name=$(gum input --placeholder "child dataset name")
        [[ -z "$name" ]] && continue
        local full="${parent}/${name}"
        gum confirm "Create dataset '$full'?" || continue
        sudo zfs create "$full" \
          && STATUS_MSG="${GRN}'$full' created${RST}" \
          || STATUS_MSG="${RED}Create failed${RST}" ;;
      "Destroy dataset")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        gum confirm "Destroy dataset '$ds'? This is irreversible." || continue
        local typed; typed=$(gum input --placeholder "Type the full dataset name to confirm")
        if [[ "$typed" != "$ds" ]]; then
          STATUS_MSG="${RED}Name mismatch — aborted${RST}"; continue; fi
        sudo zfs destroy "$ds" \
          && STATUS_MSG="${GRN}'$ds' destroyed${RST}" \
          || STATUS_MSG="${RED}Destroy failed${RST}" ;;
      "Get all properties")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        page "$(zfs get all "$ds" 2>&1)" ;;
      "Set property")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        local prop; prop=$(gum input --placeholder "property=value (e.g. compression=lz4)")
        [[ -z "$prop" ]] && continue
        sudo zfs set "$prop" "$ds" \
          && STATUS_MSG="${GRN}Property set${RST}" \
          || STATUS_MSG="${RED}Failed to set property${RST}" ;;
    esac
  done
}

snapshot_ops() {
  while true; do
    local choice
    choice=$(sub_menu "Snapshot Operations" \
      "List snapshots" \
      "Create snapshot" \
      "Destroy snapshot" \
      "Rollback" \
      "Clone" \
      "Diff" \
      "Send to file" \
      "Send to remote (SSH)" \
      "Receive from file") || return
    STATUS_MSG=""
    case "$choice" in
      "List snapshots")
        page "$(zfs list -t snapshot 2>&1)" ;;
      "Create snapshot")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        local tag; tag=$(gum input --placeholder "snapshot name (e.g. before-upgrade)" --value "$(date +%Y%m%d-%H%M%S)")
        [[ -z "$tag" ]] && continue
        sudo zfs snapshot "${ds}@${tag}" \
          && STATUS_MSG="${GRN}Snapshot '${ds}@${tag}' created${RST}" \
          || STATUS_MSG="${RED}Snapshot failed${RST}" ;;
      "Destroy snapshot")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        local snap; snap=$(pick_snapshot "$ds") || continue
        gum confirm "Destroy snapshot '$snap'? This is irreversible." || continue
        local typed; typed=$(gum input --placeholder "Type the full snapshot name to confirm")
        [[ "$typed" != "$snap" ]] && { STATUS_MSG="${RED}Name mismatch — aborted${RST}"; continue; }
        sudo zfs destroy "$snap" \
          && STATUS_MSG="${GRN}'$snap' destroyed${RST}" \
          || STATUS_MSG="${RED}Destroy failed${RST}" ;;
      "Rollback")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        local snap; snap=$(pick_snapshot "$ds") || continue
        gum confirm "Rolling back destroys all newer snapshots. Rollback to '$snap'?" || continue
        local typed; typed=$(gum input --placeholder "Type the full snapshot name to confirm")
        [[ "$typed" != "$snap" ]] && { STATUS_MSG="${RED}Name mismatch — aborted${RST}"; continue; }
        sudo zfs rollback -r "$snap" \
          && STATUS_MSG="${GRN}Rolled back to '$snap'${RST}" \
          || STATUS_MSG="${RED}Rollback failed${RST}" ;;
      "Clone")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        local snap; snap=$(pick_snapshot "$ds") || continue
        local cn; cn=$(gum input --placeholder "clone dataset name (e.g. pool/clone)")
        [[ -z "$cn" ]] && continue
        sudo zfs clone "$snap" "$cn" \
          && STATUS_MSG="${GRN}Cloned '$snap' → '$cn'${RST}" \
          || STATUS_MSG="${RED}Clone failed${RST}" ;;
      "Diff")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        local snaps; snaps=$(zfs list -H -t snapshot -o name -r "$ds" 2>/dev/null)
        [[ -z "$snaps" ]] && { STATUS_MSG="${RED}No snapshots found${RST}"; continue; }
        local snap1; snap1=$(echo "$snaps" | pick_pipe "Select first (older) snapshot") || continue
        local snap2; snap2=$(echo "$snaps" | pick_pipe "Select second (newer) snapshot") || continue
        local tmp; tmp=$(mktemp /tmp/zfs-diff-XXXXXX)
        sudo zfs diff "$snap1" "$snap2" > "$tmp" 2>&1
        page "$(cat "$tmp")"; rm -f "$tmp" ;;
      "Send to file")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        local snap; snap=$(pick_snapshot "$ds") || continue
        local out; out=$(gum input --placeholder "output file path (e.g. /tmp/backup.zfs)")
        [[ -z "$out" ]] && continue
        sudo zfs send "$snap" > "$out" 2>&1 \
          && STATUS_MSG="${GRN}Send complete: $out${RST}" \
          || STATUS_MSG="${RED}Send failed${RST}" ;;
      "Send to remote (SSH)")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        local snap; snap=$(pick_snapshot "$ds") || continue
        local remote; remote=$(gum input --placeholder "user@host")
        [[ -z "$remote" ]] && continue
        local rds; rds=$(gum input --placeholder "remote dataset (e.g. tank/received)")
        [[ -z "$rds" ]] && continue
        sudo zfs send "$snap" | ssh "$remote" sudo zfs receive "$rds"
        if [[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 ]]; then
          STATUS_MSG="${GRN}Remote send complete${RST}"
        else STATUS_MSG="${RED}Remote send failed${RST}"; fi ;;
      "Receive from file")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        local inf; inf=$(gum input --placeholder "input file path (e.g. /tmp/backup.zfs)")
        [[ -z "$inf" ]] && continue
        [[ ! -f "$inf" ]] && { STATUS_MSG="${RED}File not found: $inf${RST}"; continue; }
        gum confirm "Receive into '$ds' from '$inf'?" || continue
        sudo zfs receive "$ds" < "$inf" 2>&1 \
          && STATUS_MSG="${GRN}Receive complete${RST}" \
          || STATUS_MSG="${RED}Receive failed${RST}" ;;
    esac
  done
}

encryption_ops() {
  while true; do
    local choice
    choice=$(sub_menu "Encryption" \
      "Key status" \
      "Load key" \
      "Unload key") || return
    STATUS_MSG=""
    case "$choice" in
      "Key status")
        local pool; pool=$(pick_pool) || continue
        page "$(zfs get keystatus,encryption,keyformat -r "$pool" 2>&1)" ;;
      "Load key")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        sudo zfs load-key "$ds" \
          && STATUS_MSG="${GRN}Key loaded for '$ds'${RST}" \
          || STATUS_MSG="${RED}Key load failed${RST}" ;;
      "Unload key")
        local pool; pool=$(pick_pool) || continue
        local ds; ds=$(pick_dataset "$pool") || continue
        gum confirm "Unload key for '$ds'? Dataset will become inaccessible." || continue
        sudo zfs unload-key "$ds" \
          && STATUS_MSG="${GRN}Key unloaded for '$ds'${RST}" \
          || STATUS_MSG="${RED}Key unload failed${RST}" ;;
    esac
  done
}

# ── Handle selection ─────────────────────────────────────────────────────────

handle_select() {
  if (( FOCUS == 0 )); then
    # Pools box — show detail for selected pool/dataset
    (( POOL_CUR >= ${#POOL_NAMES[@]} )) && return
    local name="${POOL_NAMES[$POOL_CUR]}"
    [[ -z "$name" ]] && return
    pause_tui
    if zpool list -H -o name "$name" &>/dev/null 2>&1; then
      page "$(zpool status -v "$name" 2>&1)"
    else
      page "$(zfs get all "$name" 2>&1)"
    fi
    refresh_pools
    resume_tui
  else
    # Configure box
    pause_tui
    case "${CONF_ITEMS[$CONF_CUR]}" in
      "Pool Operations")     pool_ops ;;
      "Dataset Operations")  dataset_ops ;;
      "Snapshot Operations") snapshot_ops ;;
      "Encryption")          encryption_ops ;;
    esac
    refresh_pools
    resume_tui
  fi
}

# ── Main loop ────────────────────────────────────────────────────────────────

main() {
  if ! command -v zpool &>/dev/null || ! command -v zfs &>/dev/null; then
    echo "${RED}ZFS utilities (zpool/zfs) not found${RST}"
    read -rn1 -p "Press any key to close..."
    exit 1
  fi

  refresh_pools
  enter_tui

  while true; do
    draw_screen
    local key
    key=$(read_key)
    case "$key" in
      UP)
        if (( FOCUS == 0 )); then
          pool_cursor_move -1
          adjust_pool_scroll
        else
          (( CONF_CUR > 0 )) && (( CONF_CUR-- ))
        fi ;;
      DOWN)
        if (( FOCUS == 0 )); then
          pool_cursor_move 1
          adjust_pool_scroll
        else
          (( CONF_CUR < ${#CONF_ITEMS[@]} - 1 )) && (( CONF_CUR++ ))
        fi ;;
      TAB|SHIFT_TAB)
        FOCUS=$(( 1 - FOCUS ))
        STATUS_MSG="" ;;
      ENTER|RIGHT)
        handle_select ;;
      LEFT|ESC)
        break ;;
      QUIT)
        break ;;
    esac
  done
}

main
