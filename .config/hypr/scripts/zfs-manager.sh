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
  local y=$1 w=$2 h=$3 title="$4" active=$5 cursor=$6 scroll=$7 lpad=$8 col_hdr="$9"
  shift 9
  local items=("$@")
  local lpad_str=""
  (( lpad > 0 )) && printf -v lpad_str '%*s' "$lpad" ''

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
  printf '%s%s┌─ %s%s%s %s' "$lpad_str" "$bc" "${B}${tc}" "$title" "${RST}${bc}" "$bc"
  hline '─' $((w - tlen - 5))
  printf '┐%s\e[K' "$RST"

  local content_start=$((y + 1))

  # Pinned column header row (no separator line)
  if [[ -n "$col_hdr" ]]; then
    m "$content_start" 1
    local vl; vl=$(vislen "$col_hdr")
    local pad=$((inner_w - 2 - vl))
    (( pad < 0 )) && pad=0
    printf '%s%s│%s  %b%*s%s│%s\e[K' "$lpad_str" "$bc" "$RST" "$col_hdr" "$pad" "" "$bc" "$RST"
    ((content_start++))
  fi

  # Scrollable content area
  local inner_h=$((y + h - 1 - content_start))
  local count=${#items[@]}

  for ((row=0; row<inner_h; row++)); do
    m $((content_start + row)) 1
    printf '%s%s│%s' "$lpad_str" "$bc" "$RST"  # left border

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
  printf '%s%s└' "$lpad_str" "$bc"
  hline '─' $((w - 2))
  printf '┘%s\e[K' "$RST"
}

calc_layout() {
  LAYOUT_COLS=$(tput cols)
  LAYOUT_ROWS=$(tput lines)
  LAYOUT_BOX_W=$((LAYOUT_COLS * 99 / 100))
  (( LAYOUT_BOX_W < 40 )) && LAYOUT_BOX_W=$LAYOUT_COLS
  local avail=$((LAYOUT_ROWS - 1))  # reserve 1 row for status bar
  LAYOUT_POOL_H=$((avail * 60 / 100))
  LAYOUT_CONF_H=$((avail - LAYOUT_POOL_H))
  (( LAYOUT_POOL_H < 5 && LAYOUT_POOL_H + LAYOUT_CONF_H <= avail )) && LAYOUT_POOL_H=5
  (( LAYOUT_CONF_H < 4 && LAYOUT_POOL_H + LAYOUT_CONF_H <= avail )) && LAYOUT_CONF_H=4
  if (( LAYOUT_POOL_H + LAYOUT_CONF_H > avail )); then
    LAYOUT_POOL_H=$((avail * 60 / 100))
    LAYOUT_CONF_H=$((avail - LAYOUT_POOL_H))
  fi
}

draw_screen() {
  calc_layout
  local cols=$LAYOUT_COLS rows=$LAYOUT_ROWS
  local box_w=$LAYOUT_BOX_W
  local pool_h=$LAYOUT_POOL_H conf_h=$LAYOUT_CONF_H
  local left_pad=$(( (cols - box_w) / 2 ))

  printf '\e[H'  # home cursor (no clear — overwrite in place)

  draw_box 1 "$box_w" "$pool_h" "Pools" $((FOCUS == 0 ? 1 : 0)) "$POOL_CUR" "$POOL_SCROLL" "$left_pad" "$(pool_column_header)" "${POOL_LINES[@]}"
  draw_box $((1 + pool_h)) "$box_w" "$conf_h" "Configure" $((FOCUS == 1 ? 1 : 0)) "$CONF_CUR" 0 "$left_pad" "" "${CONF_ITEMS[@]}"

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
  calc_layout
  local pool_h=$LAYOUT_POOL_H
  local visible=$((pool_h - 3))  # subtract top border, col header, bottom border
  (( visible < 1 )) && visible=1
  if (( POOL_CUR < POOL_SCROLL )); then
    POOL_SCROLL=$POOL_CUR
  elif (( POOL_CUR >= POOL_SCROLL + visible )); then
    POOL_SCROLL=$((POOL_CUR - visible + 1))
  fi
}

# ── Command view (split pane for running commands) ──────────────────────────

CMD_STEPS=()       # top pane: step descriptions
CMD_STDOUT=()      # bottom pane: command output
CMD_STEP_SCROLL=0
CMD_OUT_SCROLL=0
CMD_STATUS=""      # custom status bar text (empty = default)
CMD_AUTO_SCROLL=1  # auto-scroll top pane to bottom
CMD_RESULT=""      # return value from cmd_select/cmd_input/cmd_pick_*

draw_cmd_view() {
  calc_layout
  local cols=$LAYOUT_COLS rows=$LAYOUT_ROWS
  local box_w=$LAYOUT_BOX_W
  local left_pad=$(( (cols - box_w) / 2 ))
  local avail=$((rows - 1))
  local top_h=$((avail * 60 / 100))
  local bot_h=$((avail - top_h))

  if (( CMD_AUTO_SCROLL )); then
    local top_inner=$((top_h - 2))
    (( top_inner < 1 )) && top_inner=1
    if (( ${#CMD_STEPS[@]} > top_inner )); then
      CMD_STEP_SCROLL=$(( ${#CMD_STEPS[@]} - top_inner ))
    else
      CMD_STEP_SCROLL=0
    fi
  fi

  printf '\e[H'
  draw_box 1 "$box_w" "$top_h" "Commands" 1 -1 "$CMD_STEP_SCROLL" "$left_pad" "" "${CMD_STEPS[@]}"
  draw_box $((1 + top_h)) "$box_w" "$bot_h" "Output" 0 -1 "$CMD_OUT_SCROLL" "$left_pad" "" "${CMD_STDOUT[@]}"

  m $((rows)) 1
  if [[ -n "$CMD_STATUS" ]]; then
    printf '%b\e[K\e[J' "$CMD_STATUS"
  else
    printf '%s↑↓%s scroll output  %sEnter%s/%sEsc%s continue\e[K\e[J' \
      "$CYN" "$RST" "$CYN" "$RST" "$CYN" "$RST"
  fi
}

cmd_clear() {
  CMD_STEPS=(); CMD_STDOUT=()
  CMD_STEP_SCROLL=0; CMD_OUT_SCROLL=0; CMD_STATUS=""
  CMD_AUTO_SCROLL=1
}

cmd_step() { CMD_STEPS+=("$1"); draw_cmd_view; }

cmd_scroll_bottom() {
  calc_layout
  local avail=$((LAYOUT_ROWS - 1))
  local bot_h=$((avail - avail * 60 / 100))
  local bot_inner=$((bot_h - 2))
  local max=$(( ${#CMD_STDOUT[@]} - bot_inner ))
  (( max < 0 )) && max=0
  CMD_OUT_SCROLL=$max
}

# Set scroll region + left/right margins inside top box for interactive prompts
cmd_prompt_region() {
  calc_layout
  local left_pad=$(( (LAYOUT_COLS - LAYOUT_BOX_W) / 2 ))
  local avail=$((LAYOUT_ROWS - 1))
  local top_h=$((avail * 60 / 100))
  local top_inner=$((top_h - 2))
  local step_vis=$(( ${#CMD_STEPS[@]} - CMD_STEP_SCROLL ))
  (( step_vis > top_inner )) && step_vis=$top_inner
  local row=$((2 + step_vis))
  (( row > top_h - 1 )) && row=$((top_h - 1))
  local col_left=$((left_pad + 3))
  local col_right=$((left_pad + LAYOUT_BOX_W - 2))
  # Confine cursor vertically and horizontally inside the top box
  printf '\e[%d;%dr' 2 "$((top_h - 1))"
  printf '\e[?69h'
  printf '\e[%d;%ds' "$col_left" "$col_right"
  m "$row" "$col_left"
}

# Reset scroll region + margins to full terminal
cmd_prompt_reset() {
  printf '\e[?69l'
  printf '\e[r'
}

cmd_run() {
  local desc="$1"; shift
  CMD_STEPS+=("${CYN}▸${RST} ${B}$desc${RST}")
  CMD_STEPS+=("  ${DIM}\$ $*${RST}")
  draw_cmd_view
  cmd_prompt_region; printf '\e[?25h'
  local tmp; tmp=$(mktemp /tmp/zfs-cmd-XXXXXX)
  stty sane
  "$@" > "$tmp" 2>&1
  local rc=$?
  stty -echo -icanon min 1 time 0
  printf '\e[?25l'; cmd_prompt_reset
  while IFS= read -r line; do CMD_STDOUT+=("$line"); done < "$tmp"
  rm -f "$tmp"
  if (( rc == 0 )); then CMD_STEPS+=("  ${GRN}✓${RST}")
  else CMD_STEPS+=("  ${RED}✗ exit $rc${RST}"); fi
  cmd_scroll_bottom; draw_cmd_view
  return $rc
}

cmd_page() {
  CMD_STDOUT=()
  while IFS= read -r line; do CMD_STDOUT+=("$line"); done <<< "$1"
  CMD_OUT_SCROLL=0; draw_cmd_view
}

cmd_wait() {
  CMD_STATUS=""
  while true; do
    draw_cmd_view
    local key; key=$(read_key)
    case "$key" in
      UP) (( CMD_OUT_SCROLL > 0 )) && (( CMD_OUT_SCROLL-- )) ;;
      DOWN)
        calc_layout
        local avail=$((LAYOUT_ROWS - 1))
        local bot_h=$((avail - avail * 60 / 100))
        local bot_inner=$((bot_h - 2))
        local max=$(( ${#CMD_STDOUT[@]} - bot_inner ))
        (( max < 0 )) && max=0
        (( CMD_OUT_SCROLL < max )) && (( CMD_OUT_SCROLL++ ))
        ;;
      ENTER|ESC|LEFT|QUIT) return ;;
    esac
  done
}

cmd_confirm() {
  local prompt="$1"
  CMD_STEPS+=("${CYN}?${RST} ${B}$prompt${RST}")
  CMD_STATUS="${CYN}y${RST} yes  ${CYN}n${RST} no"
  draw_cmd_view
  while true; do
    local c; IFS= read -rn1 c
    case "$c" in
      y|Y) CMD_STEPS+=("  ${GRN}yes${RST}"); CMD_STATUS=""; draw_cmd_view; return 0 ;;
      n|N) CMD_STEPS+=("  ${RED}no${RST}"); CMD_STATUS=""; draw_cmd_view; return 1 ;;
    esac
  done
}

# Native menu selection rendered inside the top box
cmd_select() {
  local header="$1"; shift
  local items=("$@")
  local cursor=0
  local count=${#items[@]}

  local saved_steps=("${CMD_STEPS[@]}")
  local saved_scroll=$CMD_STEP_SCROLL

  CMD_AUTO_SCROLL=0
  CMD_STATUS="${CYN}↑↓${RST} navigate  ${CYN}Enter${RST}/${CYN}→${RST} select  ${CYN}Esc${RST}/${CYN}←${RST} back"

  while true; do
    CMD_STEPS=("${CYN}${B}$header${RST}" "")
    for ((i=0; i<count; i++)); do
      if (( i == cursor )); then
        CMD_STEPS+=("${CYN}▸${RST} ${B}${items[$i]}${RST}")
      else
        CMD_STEPS+=("  ${items[$i]}")
      fi
    done

    # Keep cursor visible
    calc_layout
    local avail=$((LAYOUT_ROWS - 1))
    local top_inner=$((avail * 60 / 100 - 2))
    (( top_inner < 1 )) && top_inner=1
    local cursor_line=$((cursor + 2))
    if (( cursor_line < CMD_STEP_SCROLL )); then
      CMD_STEP_SCROLL=$cursor_line
    elif (( cursor_line >= CMD_STEP_SCROLL + top_inner )); then
      CMD_STEP_SCROLL=$((cursor_line - top_inner + 1))
    fi

    draw_cmd_view

    local key; key=$(read_key)
    case "$key" in
      UP) (( cursor > 0 )) && (( cursor-- )) ;;
      DOWN) (( cursor < count - 1 )) && (( cursor++ )) ;;
      ENTER|RIGHT)
        CMD_STEPS=("${saved_steps[@]}")
        CMD_STEP_SCROLL=$saved_scroll
        CMD_STEPS+=("${DIM}$header → ${items[$cursor]}${RST}")
        CMD_STATUS=""; CMD_AUTO_SCROLL=1
        CMD_RESULT="${items[$cursor]}"
        draw_cmd_view
        return 0 ;;
      ESC|LEFT|QUIT)
        CMD_STEPS=("${saved_steps[@]}")
        CMD_STEP_SCROLL=$saved_scroll
        CMD_STATUS=""; CMD_AUTO_SCROLL=1
        draw_cmd_view
        return 1 ;;
    esac
  done
}

cmd_pick_pool() {
  local pools
  pools=$(zpool list -H -o name 2>/dev/null)
  [[ -z "$pools" ]] && { cmd_step "${RED}No pools found${RST}"; return 1; }
  local count; count=$(echo "$pools" | wc -l)
  if (( count == 1 )); then CMD_RESULT="$pools"; return 0; fi
  local items=()
  while IFS= read -r p; do items+=("$p"); done <<< "$pools"
  cmd_select "Select pool" "${items[@]}"
}

cmd_pick_dataset() {
  local pool="$1" datasets
  datasets=$(zfs list -H -o name -r "$pool" 2>/dev/null)
  [[ -z "$datasets" ]] && { cmd_step "${RED}No datasets found${RST}"; return 1; }
  local count; count=$(echo "$datasets" | wc -l)
  if (( count == 1 )); then CMD_RESULT="$datasets"; return 0; fi
  local items=()
  while IFS= read -r d; do items+=("$d"); done <<< "$datasets"
  cmd_select "Select dataset" "${items[@]}"
}

cmd_pick_snapshot() {
  local dataset="$1" snaps
  if [[ -n "$dataset" ]]; then
    snaps=$(zfs list -H -t snapshot -o name -r "$dataset" 2>/dev/null)
  else
    snaps=$(zfs list -H -t snapshot -o name 2>/dev/null)
  fi
  [[ -z "$snaps" ]] && { cmd_step "${RED}No snapshots found${RST}"; return 1; }
  local count; count=$(echo "$snaps" | wc -l)
  if (( count == 1 )); then CMD_RESULT="$snaps"; return 0; fi
  local items=()
  while IFS= read -r s; do items+=("$s"); done <<< "$snaps"
  cmd_select "Select snapshot" "${items[@]}"
}

cmd_input() {
  local prompt="$1" default="$2"
  if [[ -n "$default" ]]; then
    CMD_STEPS+=("${CYN}?${RST} ${B}$prompt${RST} ${DIM}(default: $default)${RST}")
  else
    CMD_STEPS+=("${CYN}?${RST} ${B}$prompt${RST}")
  fi
  CMD_STATUS="${DIM}Type and press Enter${RST}"
  draw_cmd_view

  cmd_prompt_region; printf '\e[?25h'
  calc_layout
  local left_pad=$(( (LAYOUT_COLS - LAYOUT_BOX_W) / 2 ))
  local avail=$((LAYOUT_ROWS - 1))
  local top_h=$((avail * 60 / 100))
  local top_inner=$((top_h - 2))
  local step_vis=$(( ${#CMD_STEPS[@]} - CMD_STEP_SCROLL ))
  (( step_vis > top_inner )) && step_vis=$top_inner
  local input_row=$((2 + step_vis))
  (( input_row > top_h - 1 )) && input_row=$((top_h - 1))
  m "$input_row" $((left_pad + 3))
  printf '%s> %s' "$CYN" "$RST"

  stty sane
  local input
  read -r input
  [[ -z "$input" && -n "$default" ]] && input="$default"

  stty -echo -icanon min 1 time 0
  printf '\e[?25l'; cmd_prompt_reset
  CMD_STEPS+=("  ${DIM}${input}${RST}")
  CMD_STATUS=""
  CMD_RESULT="$input"
  draw_cmd_view
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

confirm() {
  local prompt="$1" default="${2:-Yes}"
  local items=("Yes" "No")
  [[ "$default" == "No" ]] && items=("No" "Yes")
  local choice
  choice=$(printf '%s\n' "${items[@]}" | fzf --ansi --no-info --no-sort --no-multi \
    --header "${CYN}${B}${prompt}${RST}" --header-first \
    --bind 'left:abort,right:accept' \
    --layout reverse --height 100% \
    --color 'fg:-1,bg:-1,hl:6,fg+:4:bold,bg+:-1,hl+:6,pointer:4,header:-1,border:8,label:6' \
    --pointer '▸' --no-scrollbar \
    --prompt '' --no-separator \
    --border rounded --border-label-pos bottom \
    --border-label " $SUB_HINTS ") || return 1
  [[ "$choice" == "Yes" ]]
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
    cmd_clear
    cmd_select "Pool Operations" \
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
      "Set property" || return
    local choice="$CMD_RESULT"
    STATUS_MSG=""
    case "$choice" in
      "List pools (verbose)")
        cmd_clear
        cmd_step "Listing pools..."
        cmd_page "$(zpool list -v 2>&1)"
        cmd_wait ;;
      "Detailed status / vdev tree")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_clear
        cmd_step "Pool status: ${B}$pool${RST}"
        cmd_page "$(zpool status -v "$pool" 2>&1)"
        cmd_wait ;;
      "Import pool")
        cmd_clear
        cmd_step "${B}Import Pool${RST}"

        # --- LUKS unlock phase ---
        local opened_luks=()
        local luks_devs
        cmd_prompt_region; stty sane; printf '\e[?25h'
        luks_devs=$(sudo blkid -t TYPE=crypto_LUKS -o device 2>/dev/null) || true
        stty -echo -icanon min 1 time 0; printf '\e[?25l'; cmd_prompt_reset
        if [[ -n "$luks_devs" ]]; then
          local locked_luks=()
          while IFS= read -r dev; do
            local dm_name
            dm_name=$(lsblk -nro TYPE,NAME "$dev" 2>/dev/null | awk '$1=="crypt"{print $2}')
            [[ -z "$dm_name" ]] && locked_luks+=("$dev")
          done <<< "$luks_devs"

          if [[ ${#locked_luks[@]} -gt 0 ]]; then
            local luks_labels=()
            for d in "${locked_luks[@]}"; do
              local label; label=$(lsblk -ndo LABEL "$d" 2>/dev/null)
              [[ -z "$label" ]] && { cmd_prompt_region; stty sane; printf '\e[?25h'; label=$(sudo blkid -s LABEL -o value "$d" 2>/dev/null); stty -echo -icanon min 1 time 0; printf '\e[?25l'; cmd_prompt_reset; draw_cmd_view; }
              if [[ -n "$label" ]]; then luks_labels+=("$d ($label)")
              else local sz; sz=$(lsblk -ndo SIZE "$d" 2>/dev/null); luks_labels+=("$d (${sz:-unknown})"); fi
            done

            cmd_step "Found ${#locked_luks[@]} locked LUKS device(s)"
            while cmd_confirm "Unlock a LUKS device before scanning?"; do
              luks_labels=(); locked_luks=()
              while IFS= read -r dev; do
                local dm_name
                dm_name=$(lsblk -nro TYPE,NAME "$dev" 2>/dev/null | awk '$1=="crypt"{print $2}')
                [[ -z "$dm_name" ]] && locked_luks+=("$dev")
              done <<< "$luks_devs"
              [[ ${#locked_luks[@]} -eq 0 ]] && { cmd_step "${GRN}All LUKS devices unlocked${RST}"; break; }
              for d in "${locked_luks[@]}"; do
                local label; label=$(lsblk -ndo LABEL "$d" 2>/dev/null)
                [[ -z "$label" ]] && { cmd_prompt_region; stty sane; printf '\e[?25h'; label=$(sudo blkid -s LABEL -o value "$d" 2>/dev/null); stty -echo -icanon min 1 time 0; printf '\e[?25l'; cmd_prompt_reset; draw_cmd_view; }
                if [[ -n "$label" ]]; then luks_labels+=("$d ($label)")
                else local sz; sz=$(lsblk -ndo SIZE "$d" 2>/dev/null); luks_labels+=("$d (${sz:-unknown})"); fi
              done
              cmd_select "Unlock which device?" "${luks_labels[@]}" || break
              local pick_label="$CMD_RESULT"
              [[ -z "$pick_label" ]] && break
              local pick_luks; pick_luks="${pick_label%% *}"
              local luks_name
              local label; label=$(lsblk -ndo LABEL "$pick_luks" 2>/dev/null)
              [[ -z "$label" ]] && { cmd_prompt_region; stty sane; printf '\e[?25h'; label=$(sudo blkid -s LABEL -o value "$pick_luks" 2>/dev/null); stty -echo -icanon min 1 time 0; printf '\e[?25l'; cmd_prompt_reset; draw_cmd_view; }
              if [[ -n "$label" ]]; then luks_name="crypt-${label// /-}"
              else luks_name="crypt-$(basename "$pick_luks")"; fi
              if cmd_run "Open LUKS $pick_luks → $luks_name" sudo cryptsetup open "$pick_luks" "$luks_name" --type luks; then
                opened_luks+=("$luks_name")
              fi
            done
          fi
        fi

        # --- Scan for importable pools ---
        cmd_step ""; cmd_step "Scanning for importable ZFS pools..."
        CMD_STEPS+=("  ${DIM}\$ sudo zpool import${RST}"); draw_cmd_view
        local scan
        cmd_prompt_region; stty sane; printf '\e[?25h'
        scan=$(sudo zpool import 2>&1) || true
        stty -echo -icanon min 1 time 0; printf '\e[?25l'; cmd_prompt_reset
        if [[ -n "$scan" ]]; then
          while IFS= read -r line; do CMD_STDOUT+=("$line"); done <<< "$scan"
          CMD_STEPS+=("  ${GRN}✓${RST}")
        else
          CMD_STEPS+=("  ${DIM}(no output)${RST}")
        fi
        cmd_scroll_bottom; draw_cmd_view

        if [[ -z "$scan" ]] || echo "$scan" | grep -q "no pools available"; then
          cmd_step "${YEL}No pools available to import${RST}"
          for ln in "${opened_luks[@]}"; do cmd_run "Close LUKS '$ln'" sudo cryptsetup close "$ln" 2>/dev/null || true; done
          cmd_wait; STATUS_MSG="${YEL}No pools found${RST}"; continue
        fi

        local names; names=$(echo "$scan" | grep "pool:" | awk '{print $2}')
        if [[ -z "$names" ]]; then
          cmd_step "${YEL}Could not parse pool names${RST}"
          for ln in "${opened_luks[@]}"; do cmd_run "Close LUKS '$ln'" sudo cryptsetup close "$ln" 2>/dev/null || true; done
          cmd_wait; STATUS_MSG="${YEL}Could not parse pool names${RST}"; continue
        fi

        # Pool selection
        local name_items=()
        while IFS= read -r n; do name_items+=("$n"); done <<< "$names"
        cmd_select "Import which pool?" "${name_items[@]}" || {
          for ln in "${opened_luks[@]}"; do cmd_run "Close LUKS '$ln'" sudo cryptsetup close "$ln" 2>/dev/null || true; done
          continue
        }
        local pick="$CMD_RESULT"

        cmd_step ""; cmd_step "Importing pool '${B}$pick${RST}'..."
        if ! cmd_run "Import pool '$pick'" sudo zpool import "$pick"; then
          for ln in "${opened_luks[@]}"; do cmd_run "Close LUKS '$ln'" sudo cryptsetup close "$ln" 2>/dev/null || true; done
          cmd_wait; STATUS_MSG="${RED}Failed to import '$pick'${RST}"; continue
        fi

        # Load encryption keys
        local enc_ds
        enc_ds=$(zfs get -H -r -o name,value keystatus "$pick" 2>/dev/null \
          | awk -F'\t' '$2 == "unavailable" {print $1}')
        if [[ -n "$enc_ds" ]]; then
          cmd_step ""; cmd_step "Loading encryption keys..."
          while IFS= read -r ds; do
            local kf; kf=$(zfs get -H -o value keyformat "$ds" 2>/dev/null)
            case "$kf" in
              passphrase)
                cmd_run "Load key for $ds" sudo zfs load-key "$ds" || true ;;
              raw|hex)
                cmd_input "Key file path for $ds"; local keyfile="$CMD_RESULT"
                if [[ -n "$keyfile" && -f "$keyfile" ]]; then
                  cmd_run "Load key for $ds" sudo zfs load-key -L "file://$keyfile" "$ds" || true
                else
                  cmd_step "  ${YEL}Skipping $ds — no key file provided${RST}"
                fi ;;
            esac
          done <<< "$enc_ds"
        fi

        cmd_step ""; cmd_step "Mounting datasets..."
        cmd_run "Mount all" sudo zfs mount -a -l || true
        cmd_step ""; cmd_step "${GRN}Done — pool '$pick' imported and mounted${RST}"
        cmd_wait
        STATUS_MSG="${GRN}Pool '$pick' imported and mounted${RST}" ;;

      "Export pool")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_confirm "Export pool '$pool'?" || continue

        cmd_clear
        cmd_step "${B}Exporting pool '$pool'${RST}"

        # Capture backing devices BEFORE export
        local mapper_devs=()
        local -a vdevs
        mapfile -t vdevs < <(zpool status -LP "$pool" 2>/dev/null | awk '/\/dev\//{print $1}')
        if (( ${#vdevs[@]} > 0 )); then
          for dev in "${vdevs[@]}"; do
            if [[ "$dev" == /dev/mapper/* ]]; then
              mapper_devs+=("$(basename "$dev")")
            elif [[ "$dev" == /dev/dm-* ]]; then
              local mname
              mname=$(sudo dmsetup info -c --noheadings -o name "$dev" 2>/dev/null) || true
              [[ -n "$mname" ]] && mapper_devs+=("$mname")
            fi
          done
        fi

        # Unmount all datasets (deepest first)
        local mounted
        mounted=$(zfs list -H -o name,mounted -r "$pool" 2>/dev/null \
          | awk -F'\t' '$2 == "yes" {print $1}' | sort -r)
        if [[ -n "$mounted" ]]; then
          cmd_step "Unmounting datasets..."
          while IFS= read -r ds; do
            cmd_run "Unmount $ds" sudo zfs unmount "$ds" || true
          done <<< "$mounted"
        fi

        # Unload encryption keys
        local enc_ds
        enc_ds=$(zfs get -H -r -o name,value keystatus "$pool" 2>/dev/null \
          | awk -F'\t' '$2 == "available" {print $1}') || true
        if [[ -n "$enc_ds" ]]; then
          if cmd_confirm "Unload ZFS encryption keys?"; then
            cmd_step "Unloading encryption keys..."
            while IFS= read -r ds; do
              cmd_run "Unload key for $ds" sudo zfs unload-key "$ds" || true
            done <<< "$enc_ds"
          else
            cmd_step "${DIM}Skipping ZFS key unload${RST}"
          fi
        fi

        # Export
        if ! cmd_run "Export pool '$pool'" sudo zpool export "$pool"; then
          if cmd_confirm "Force export '$pool'?"; then
            if ! cmd_run "Force export pool '$pool'" sudo zpool export -f "$pool"; then
              cmd_wait; STATUS_MSG="${RED}Force export failed${RST}"; continue
            fi
          else
            cmd_wait; STATUS_MSG="${RED}Export aborted${RST}"; continue
          fi
        fi

        # Close LUKS mapper devices
        for mname in "${mapper_devs[@]}"; do
          if [[ -e "/dev/mapper/$mname" ]]; then
            if cmd_confirm "Close LUKS device '$mname'?"; then
              cmd_run "Close LUKS $mname" sudo cryptsetup close "$mname" || true
            else
              cmd_step "${DIM}Skipping LUKS close for $mname${RST}"
            fi
          fi
        done

        cmd_step ""; cmd_step "${GRN}Done — pool '$pool' exported${RST}"
        cmd_wait
        STATUS_MSG="${GRN}Pool '$pool' exported${RST}" ;;
      "Start scrub")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_clear
        cmd_run "Start scrub on '$pool'" sudo zpool scrub "$pool" \
          && STATUS_MSG="${GRN}Scrub started on '$pool'${RST}" \
          || STATUS_MSG="${RED}Scrub failed${RST}"
        cmd_wait ;;
      "Cancel scrub")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_clear
        cmd_run "Cancel scrub on '$pool'" sudo zpool scrub -s "$pool" \
          && STATUS_MSG="${GRN}Scrub cancelled on '$pool'${RST}" \
          || STATUS_MSG="${RED}Cancel failed${RST}"
        cmd_wait ;;
      "Trim")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_confirm "Start TRIM on '$pool'?" || continue
        cmd_clear
        cmd_run "TRIM '$pool'" sudo zpool trim "$pool" \
          && STATUS_MSG="${GRN}TRIM started on '$pool'${RST}" \
          || STATUS_MSG="${RED}TRIM failed${RST}"
        cmd_wait ;;
      "I/O stats")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_clear
        cmd_step "I/O stats: ${B}$pool${RST} ${DIM}(5s intervals × 3)${RST}"
        cmd_page "$(zpool iostat -v "$pool" 5 3 2>&1)"
        cmd_wait ;;
      "History")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_clear
        cmd_step "History: ${B}$pool${RST}"
        cmd_page "$(sudo zpool history "$pool" 2>&1)"
        cmd_wait ;;
      "Upgrade features")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_clear
        cmd_step "Feature flags: ${B}$pool${RST}"
        cmd_page "$(sudo zpool upgrade -v "$pool" 2>&1)"
        if cmd_confirm "Upgrade pool '$pool' features?"; then
          cmd_run "Upgrade pool features" sudo zpool upgrade "$pool" \
            && STATUS_MSG="${GRN}Upgrade complete${RST}" \
            || STATUS_MSG="${RED}Upgrade failed${RST}"
        fi
        cmd_wait ;;
      "Get all properties")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_clear
        cmd_step "Properties: ${B}$pool${RST}"
        cmd_page "$(zpool get all "$pool" 2>&1)"
        cmd_wait ;;
      "Set property")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_input "property=value (e.g. comment=mypool)"; local prop="$CMD_RESULT"
        [[ -z "$prop" ]] && continue
        cmd_clear
        cmd_run "Set property on '$pool'" sudo zpool set "$prop" "$pool" \
          && STATUS_MSG="${GRN}Property set${RST}" \
          || STATUS_MSG="${RED}Failed to set property${RST}"
        cmd_wait ;;
    esac
  done
}

dataset_ops() {
  while true; do
    cmd_clear
    cmd_select "Dataset Operations" \
      "List datasets" \
      "Mount" \
      "Unmount" \
      "Create dataset" \
      "Destroy dataset" \
      "Get all properties" \
      "Set property" || return
    local choice="$CMD_RESULT"
    STATUS_MSG=""
    case "$choice" in
      "List datasets")
        cmd_clear
        cmd_step "Listing datasets..."
        cmd_page "$(zfs list 2>&1)"
        cmd_wait ;;
      "Mount")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_clear
        cmd_run "Mount '$ds'" sudo zfs mount "$ds" \
          && STATUS_MSG="${GRN}'$ds' mounted${RST}" \
          || STATUS_MSG="${RED}Mount failed${RST}"
        cmd_wait ;;
      "Unmount")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_confirm "Unmount '$ds'?" || continue
        cmd_clear
        cmd_run "Unmount '$ds'" sudo zfs unmount "$ds" \
          && STATUS_MSG="${GRN}'$ds' unmounted${RST}" \
          || STATUS_MSG="${RED}Unmount failed${RST}"
        cmd_wait ;;
      "Create dataset")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local parent="$CMD_RESULT"
        cmd_input "child dataset name"; local name="$CMD_RESULT"
        [[ -z "$name" ]] && continue
        local full="${parent}/${name}"
        cmd_confirm "Create dataset '$full'?" || continue
        cmd_clear
        cmd_run "Create dataset '$full'" sudo zfs create "$full" \
          && STATUS_MSG="${GRN}'$full' created${RST}" \
          || STATUS_MSG="${RED}Create failed${RST}"
        cmd_wait ;;
      "Destroy dataset")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_confirm "Destroy dataset '$ds'? This is irreversible." || continue
        cmd_input "Type the full dataset name to confirm"; local typed="$CMD_RESULT"
        if [[ "$typed" != "$ds" ]]; then
          STATUS_MSG="${RED}Name mismatch — aborted${RST}"; continue; fi
        cmd_clear
        cmd_run "Destroy dataset '$ds'" sudo zfs destroy "$ds" \
          && STATUS_MSG="${GRN}'$ds' destroyed${RST}" \
          || STATUS_MSG="${RED}Destroy failed${RST}"
        cmd_wait ;;
      "Get all properties")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_clear
        cmd_step "Properties: ${B}$ds${RST}"
        cmd_page "$(zfs get all "$ds" 2>&1)"
        cmd_wait ;;
      "Set property")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_input "property=value (e.g. compression=lz4)"; local prop="$CMD_RESULT"
        [[ -z "$prop" ]] && continue
        cmd_clear
        cmd_run "Set property on '$ds'" sudo zfs set "$prop" "$ds" \
          && STATUS_MSG="${GRN}Property set${RST}" \
          || STATUS_MSG="${RED}Failed to set property${RST}"
        cmd_wait ;;
    esac
  done
}

snapshot_ops() {
  while true; do
    cmd_clear
    cmd_select "Snapshot Operations" \
      "List snapshots" \
      "Create snapshot" \
      "Destroy snapshot" \
      "Rollback" \
      "Clone" \
      "Diff" \
      "Send to file" \
      "Send to remote (SSH)" \
      "Receive from file" || return
    local choice="$CMD_RESULT"
    STATUS_MSG=""
    case "$choice" in
      "List snapshots")
        cmd_clear
        cmd_step "Listing snapshots..."
        cmd_page "$(zfs list -t snapshot 2>&1)"
        cmd_wait ;;
      "Create snapshot")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_input "snapshot name (e.g. before-upgrade)" "$(date +%Y%m%d-%H%M%S)"; local tag="$CMD_RESULT"
        [[ -z "$tag" ]] && continue
        cmd_clear
        cmd_run "Create snapshot '${ds}@${tag}'" sudo zfs snapshot "${ds}@${tag}" \
          && STATUS_MSG="${GRN}Snapshot '${ds}@${tag}' created${RST}" \
          || STATUS_MSG="${RED}Snapshot failed${RST}"
        cmd_wait ;;
      "Destroy snapshot")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_pick_snapshot "$ds" || continue; local snap="$CMD_RESULT"
        cmd_confirm "Destroy snapshot '$snap'? This is irreversible." || continue
        cmd_input "Type the full snapshot name to confirm"; local typed="$CMD_RESULT"
        [[ "$typed" != "$snap" ]] && { STATUS_MSG="${RED}Name mismatch — aborted${RST}"; continue; }
        cmd_clear
        cmd_run "Destroy snapshot '$snap'" sudo zfs destroy "$snap" \
          && STATUS_MSG="${GRN}'$snap' destroyed${RST}" \
          || STATUS_MSG="${RED}Destroy failed${RST}"
        cmd_wait ;;
      "Rollback")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_pick_snapshot "$ds" || continue; local snap="$CMD_RESULT"
        cmd_confirm "Rolling back destroys all newer snapshots. Rollback to '$snap'?" || continue
        cmd_input "Type the full snapshot name to confirm"; local typed="$CMD_RESULT"
        [[ "$typed" != "$snap" ]] && { STATUS_MSG="${RED}Name mismatch — aborted${RST}"; continue; }
        cmd_clear
        cmd_run "Rollback to '$snap'" sudo zfs rollback -r "$snap" \
          && STATUS_MSG="${GRN}Rolled back to '$snap'${RST}" \
          || STATUS_MSG="${RED}Rollback failed${RST}"
        cmd_wait ;;
      "Clone")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_pick_snapshot "$ds" || continue; local snap="$CMD_RESULT"
        cmd_input "clone dataset name (e.g. pool/clone)"; local cn="$CMD_RESULT"
        [[ -z "$cn" ]] && continue
        cmd_clear
        cmd_run "Clone '$snap' → '$cn'" sudo zfs clone "$snap" "$cn" \
          && STATUS_MSG="${GRN}Cloned '$snap' → '$cn'${RST}" \
          || STATUS_MSG="${RED}Clone failed${RST}"
        cmd_wait ;;
      "Diff")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        local snaps; snaps=$(zfs list -H -t snapshot -o name -r "$ds" 2>/dev/null)
        [[ -z "$snaps" ]] && { STATUS_MSG="${RED}No snapshots found${RST}"; continue; }
        local snap_items=()
        while IFS= read -r s; do snap_items+=("$s"); done <<< "$snaps"
        cmd_select "Select first (older) snapshot" "${snap_items[@]}" || continue
        local snap1="$CMD_RESULT"
        cmd_select "Select second (newer) snapshot" "${snap_items[@]}" || continue
        local snap2="$CMD_RESULT"
        cmd_clear
        cmd_step "Diff: ${B}$snap1${RST} vs ${B}$snap2${RST}"
        cmd_run "Diff snapshots" sudo zfs diff "$snap1" "$snap2"
        cmd_wait ;;
      "Send to file")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_pick_snapshot "$ds" || continue; local snap="$CMD_RESULT"
        cmd_input "output file path (e.g. /tmp/backup.zfs)"; local out="$CMD_RESULT"
        [[ -z "$out" ]] && continue
        cmd_clear
        cmd_step "Sending ${B}$snap${RST} to ${B}$out${RST}..."
        CMD_STEPS+=("  ${DIM}\$ sudo zfs send $snap > $out${RST}")
        draw_cmd_view; cmd_prompt_pos
        local err_tmp; err_tmp=$(mktemp /tmp/zfs-cmd-XXXXXX)
        stty sane; printf '\e[?25h'
        sudo zfs send "$snap" > "$out" 2>"$err_tmp"
        local rc=$?
        stty -echo -icanon min 1 time 0; printf '\e[?25l'; cmd_prompt_reset
        while IFS= read -r line; do CMD_STDOUT+=("$line"); done < "$err_tmp"
        rm -f "$err_tmp"
        if (( rc == 0 )); then CMD_STEPS+=("  ${GRN}✓${RST}"); STATUS_MSG="${GRN}Send complete: $out${RST}"
        else CMD_STEPS+=("  ${RED}✗ exit $rc${RST}"); STATUS_MSG="${RED}Send failed${RST}"; fi
        cmd_scroll_bottom; draw_cmd_view
        cmd_wait ;;
      "Send to remote (SSH)")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_pick_snapshot "$ds" || continue; local snap="$CMD_RESULT"
        cmd_input "user@host"; local remote="$CMD_RESULT"
        [[ -z "$remote" ]] && continue
        cmd_input "remote dataset (e.g. tank/received)"; local rds="$CMD_RESULT"
        [[ -z "$rds" ]] && continue
        cmd_clear
        cmd_step "Sending ${B}$snap${RST} to ${B}$remote:$rds${RST}..."
        CMD_STEPS+=("  ${DIM}\$ sudo zfs send $snap | ssh $remote sudo zfs receive $rds${RST}")
        draw_cmd_view; cmd_prompt_pos
        local err_tmp; err_tmp=$(mktemp /tmp/zfs-cmd-XXXXXX)
        stty sane; printf '\e[?25h'
        sudo zfs send "$snap" 2>"$err_tmp" | ssh "$remote" sudo zfs receive "$rds" 2>>"$err_tmp"
        local p0=${PIPESTATUS[0]} p1=${PIPESTATUS[1]}
        stty -echo -icanon min 1 time 0; printf '\e[?25l'; cmd_prompt_reset
        while IFS= read -r line; do CMD_STDOUT+=("$line"); done < "$err_tmp"
        rm -f "$err_tmp"
        if (( p0 == 0 && p1 == 0 )); then
          CMD_STEPS+=("  ${GRN}✓${RST}"); STATUS_MSG="${GRN}Remote send complete${RST}"
        else
          CMD_STEPS+=("  ${RED}✗ send=$p0 receive=$p1${RST}"); STATUS_MSG="${RED}Remote send failed${RST}"
        fi
        cmd_scroll_bottom; draw_cmd_view
        cmd_wait ;;
      "Receive from file")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_input "input file path (e.g. /tmp/backup.zfs)"; local inf="$CMD_RESULT"
        [[ -z "$inf" ]] && continue
        [[ ! -f "$inf" ]] && { STATUS_MSG="${RED}File not found: $inf${RST}"; continue; }
        cmd_confirm "Receive into '$ds' from '$inf'?" || continue
        cmd_clear
        cmd_step "Receiving ${B}$inf${RST} into ${B}$ds${RST}..."
        CMD_STEPS+=("  ${DIM}\$ sudo zfs receive $ds < $inf${RST}")
        draw_cmd_view; cmd_prompt_pos
        local err_tmp; err_tmp=$(mktemp /tmp/zfs-cmd-XXXXXX)
        stty sane; printf '\e[?25h'
        sudo zfs receive "$ds" < "$inf" 2>"$err_tmp"
        local rc=$?
        stty -echo -icanon min 1 time 0; printf '\e[?25l'; cmd_prompt_reset
        while IFS= read -r line; do CMD_STDOUT+=("$line"); done < "$err_tmp"
        rm -f "$err_tmp"
        if (( rc == 0 )); then CMD_STEPS+=("  ${GRN}✓${RST}"); STATUS_MSG="${GRN}Receive complete${RST}"
        else CMD_STEPS+=("  ${RED}✗ exit $rc${RST}"); STATUS_MSG="${RED}Receive failed${RST}"; fi
        cmd_scroll_bottom; draw_cmd_view
        cmd_wait ;;
    esac
  done
}

encryption_ops() {
  while true; do
    cmd_clear
    cmd_select "Encryption" \
      "Key status" \
      "Load key" \
      "Unload key" || return
    local choice="$CMD_RESULT"
    STATUS_MSG=""
    case "$choice" in
      "Key status")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_clear
        cmd_step "Key status: ${B}$pool${RST}"
        cmd_page "$(zfs get keystatus,encryption,keyformat -r "$pool" 2>&1)"
        cmd_wait ;;
      "Load key")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_clear
        cmd_run "Load key for '$ds'" sudo zfs load-key "$ds" \
          && STATUS_MSG="${GRN}Key loaded for '$ds'${RST}" \
          || STATUS_MSG="${RED}Key load failed${RST}"
        cmd_wait ;;
      "Unload key")
        cmd_pick_pool || continue; local pool="$CMD_RESULT"
        cmd_pick_dataset "$pool" || continue; local ds="$CMD_RESULT"
        cmd_confirm "Unload key for '$ds'? Dataset will become inaccessible." || continue
        cmd_clear
        cmd_run "Unload key for '$ds'" sudo zfs unload-key "$ds" \
          && STATUS_MSG="${GRN}Key unloaded for '$ds'${RST}" \
          || STATUS_MSG="${RED}Key unload failed${RST}"
        cmd_wait ;;
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
    cmd_clear
    if zpool list -H -o name "$name" &>/dev/null 2>&1; then
      cmd_step "Pool status: ${B}$name${RST}"
      cmd_page "$(zpool status -v "$name" 2>&1)"
    else
      cmd_step "Dataset properties: ${B}$name${RST}"
      cmd_page "$(zfs get all "$name" 2>&1)"
    fi
    cmd_wait
    refresh_pools
  else
    # Configure box — enter command view (stays on alt screen)
    cmd_clear; draw_cmd_view
    case "${CONF_ITEMS[$CONF_CUR]}" in
      "Pool Operations")     pool_ops ;;
      "Dataset Operations")  dataset_ops ;;
      "Snapshot Operations") snapshot_ops ;;
      "Encryption")          encryption_ops ;;
    esac
    refresh_pools
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
