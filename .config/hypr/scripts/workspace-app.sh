#!/bin/bash
# Per-workspace default program on Super+Middle-click.
#
#   Super+Middle on an empty desktop launches the workspace's default program.
#   Shift+Super+Middle opens the picker to change it. With no default set, the
#   plain click opens the same picker. The picker (tla.workspace-apps overlay,
#   a clipboard-manager lookalike) lists the workspace's earlier defaults and
#   recently launched programs, accepts a typed command, and can test-run a
#   row without setting it.
#
# Usage: workspace-app.sh <command> [args]
#   launch          click handler: launch the default, or pick when unset
#   set             click handler: always open the picker
#   rows <ws>       print the picker rows for a workspace as JSON
#   forget <key>    drop an entry from the recent and previous lists
#   run <mon> <entry-json>   launch one entry on a monitor (used internally)
#
# State: ~/.local/state/hypr/workspace-apps.json
#   defaults  {ws: entry}          the current default per workspace
#   previous  {ws: [entry, ...]}   earlier defaults per workspace, newest first
#   recent    [entry+lastUsed+uses] everything launched or seen running
#
# "Recent" needs no daemon: every launch through here is recorded, and each
# time the picker opens the running windows are folded in with their process
# start time, so anything that was ever open while picking shows up.
#
# Overridable for tests: WORKSPACE_APP_STATE, WORKSPACE_APP_DIRS (colon list
# of applications dirs), WORKSPACE_APP_PROC (fake /proc root).

set -u

STATE_FILE="${WORKSPACE_APP_STATE:-$HOME/.local/state/hypr/workspace-apps.json}"
APP_DIRS="${WORKSPACE_APP_DIRS:-$HOME/.local/share/applications:/usr/share/applications}"
PROC_ROOT="${WORKSPACE_APP_PROC:-/proc}"
PLUGIN_ID="tla.workspace-apps"
RECENT_CAP=50
PREVIOUS_CAP=10

# --- state ------------------------------------------------------------------

state_read() {
  local raw="{}"
  [[ -s $STATE_FILE ]] && raw=$(cat "$STATE_FILE")
  jq -c '
    (if type == "object" then . else {} end)
    | {defaults: (.defaults // {}), previous: (.previous // {}), recent: (.recent // [])}
  ' <<<"$raw" 2>/dev/null || echo '{"defaults":{},"previous":{},"recent":[]}'
}

state_write() { # <json> on stdin
  mkdir -p "$(dirname "$STATE_FILE")"
  local tmp
  tmp=$(mktemp "$STATE_FILE.XXXXXX") || return 1
  jq '.' >"$tmp" && mv "$tmp" "$STATE_FILE"
}

# The stable identity of an entry: its desktop id, or the literal command.
entry_key() { # <entry-json>
  jq -r 'if .kind == "desktop" then "desktop:" + .id else "command:" + .exec end' <<<"$1"
}

# Strip picker-only fields so what lands in defaults/previous is just the entry.
entry_core() { # <entry-json>
  jq -c '{kind, id, label, icon, exec, file} | with_entries(select(.value != null))' <<<"$1"
}

# Upsert into recent: newest first, capped. bump=1 counts a real launch;
# a snapshot only moves lastUsed forward, never back.
record_recent() { # <entry-json> <epoch> <bump>
  local entry epoch bump
  entry=$(entry_core "$1"); epoch="$2"; bump="$3"
  state_read | jq -c --argjson e "$entry" --argjson t "$epoch" --argjson bump "$bump" --argjson cap "$RECENT_CAP" '
    ($e | if .kind == "desktop" then "desktop:" + .id else "command:" + .exec end) as $key
    | (.recent | map(select(
        (if .kind == "desktop" then "desktop:" + .id else "command:" + .exec end) == $key
      )) | first) as $old
    | .recent = (
        [ $e + {
            lastUsed: ([$t, ($old.lastUsed // 0)] | max),
            uses: (($old.uses // 0) + $bump)
          } ]
        + (.recent | map(select(
            (if .kind == "desktop" then "desktop:" + .id else "command:" + .exec end) != $key
          )))
      )
    | .recent |= (sort_by(-.lastUsed) | .[:$cap])
  ' | state_write
}

set_default() { # <ws> <entry-json>
  local ws entry
  ws="$1"; entry=$(entry_core "$2")
  state_read | jq -c --arg ws "$ws" --argjson e "$entry" --argjson cap "$PREVIOUS_CAP" '
    def key: if .kind == "desktop" then "desktop:" + .id else "command:" + .exec end;
    ($e | key) as $new
    | .defaults[$ws] as $old
    | .previous[$ws] = (
        (if $old != null and ($old | key) != $new then [$old] else [] end)
        + ((.previous[$ws] // []) | map(select((key) != $new and (key) != ($old | if . == null then "" else key end))))
      | .[:$cap])
    | .defaults[$ws] = $e
  ' | state_write
}

forget_key() { # <key>
  state_read | jq -c --arg key "$1" '
    def key: if .kind == "desktop" then "desktop:" + .id else "command:" + .exec end;
    .recent |= map(select((key) != $key))
    | .previous |= with_entries(.value |= map(select((key) != $key)))
  ' | state_write
}

# --- desktop entries --------------------------------------------------------

# Read the [Desktop Entry] group of a .desktop file as JSON.
desktop_entry_json() { # <file>
  local file="$1" id
  id=$(basename "$file" .desktop)
  awk '/^\[/{n++} n==1' "$file" | jq -Rs --arg id "$id" --arg file "$file" '
    split("\n")
    | map(select(test("^(Name|Icon|Exec)=")) | capture("^(?<k>[^=]+)=(?<v>.*)$"))
    | map({key: (.k | ascii_downcase), value: .v}) | from_entries
    | {kind: "desktop", id: $id, label: (.name // $id), icon: (.icon // ""), exec: (.exec // ""), file: $file}
  '
}

# Map a window class to its desktop file: basename first (org.gnome.Nautilus,
# foot, firefox), then StartupWMClass. Case-insensitive, first hit wins in
# APP_DIRS order.
resolve_class() { # <class>
  local class="$1" dir file base lc
  [[ -n $class ]] || return 1
  lc=${class,,}
  IFS=: read -ra dirs <<<"$APP_DIRS"
  for dir in "${dirs[@]}"; do
    [[ -d $dir ]] || continue
    for file in "$dir"/*.desktop; do
      [[ -e $file ]] || continue
      base=$(basename "$file" .desktop)
      if [[ ${base,,} == "$lc" ]]; then
        desktop_entry_json "$file"
        return 0
      fi
    done
  done
  for dir in "${dirs[@]}"; do
    [[ -d $dir ]] || continue
    file=$(grep -il -m1 "^StartupWMClass=${class}\$" "$dir"/*.desktop 2>/dev/null | head -1)
    if [[ -n $file ]]; then
      desktop_entry_json "$file"
      return 0
    fi
  done
  return 1
}

# Epoch seconds a process started, from /proc; "now" when unreadable.
proc_start_epoch() { # <pid>
  local btime ticks hz
  btime=$(awk '/^btime/{print $2}' "$PROC_ROOT/stat" 2>/dev/null)
  ticks=$(sed 's/.*) //' "$PROC_ROOT/$1/stat" 2>/dev/null | awk '{print $20}')
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  if [[ -n $btime && -n $ticks ]]; then
    echo $((btime + ticks / hz))
  else
    date +%s
  fi
}

# Fold the running windows into recent, newest start per class.
snapshot_running() {
  local clients line class pid start entry
  clients=$(hyprctl -j clients 2>/dev/null) || return 0
  while IFS=$'\t' read -r class pid; do
    [[ -n $class ]] || continue
    start=$(proc_start_epoch "$pid")
    entry=$(resolve_class "$class") || continue
    record_recent "$entry" "$start" 0
  done < <(jq -r '
    map(select(.mapped and (.hidden | not) and (.class // "") != ""))
    | group_by(.class) | map(max_by(.pid)) | .[] | [.class, .pid] | @tsv
  ' <<<"$clients")
}

# --- picker rows ------------------------------------------------------------

rows_for() { # <ws>
  state_read | jq -c --arg ws "$1" '
    def key: if .kind == "desktop" then "desktop:" + .id else "command:" + .exec end;
    def row(section): . + {
      key: key,
      subtext: (if .kind == "desktop" then (.exec // .id) else .exec end),
      section: section
    };
    . as $s
    | ([$s.defaults[$ws] | select(. != null) | row("current")]
       + (($s.previous[$ws] // []) | map(row("previous")))
       + ($s.recent | map(row("recent"))))
    | reduce .[] as $r ([]; if any(.[]; .key == $r.key) then . else . + [$r] end)
    | map(. as $r | . + {
        defaultFor: [$s.defaults | to_entries[] | select((.value | key) == $r.key) | .key | tonumber] | sort
      })
  ' 2>/dev/null || echo "[]"
}

# --- pointer context --------------------------------------------------------

# Where the click landed: {monitor, workspace, onDesktop}. onDesktop is false
# over any mapped window on that monitor's visible workspaces or inside the
# reserved bar strip.
cursor_context() {
  local cur mons clients
  cur=$(hyprctl -j cursorpos) || return 1
  mons=$(hyprctl -j monitors) || return 1
  clients=$(hyprctl -j clients) || return 1
  jq -c --argjson cur "$cur" --argjson clients "$clients" '
    map(select(.disabled | not))
    | map(. + {
        lw: (if ((.transform // 0) % 2) == 1 then .height else .width end) / (.scale // 1),
        lh: (if ((.transform // 0) % 2) == 1 then .width else .height end) / (.scale // 1)
      })
    | map(select($cur.x >= .x and $cur.x < .x + .lw and $cur.y >= .y and $cur.y < .y + .lh))
    | first as $mon
    | if $mon == null then {onDesktop: false}
      else
        ($mon.reserved // [0,0,0,0]) as $r
        | ($cur.x < $mon.x + $r[0] or $cur.y < $mon.y + $r[1]
           or $cur.x >= $mon.x + $mon.lw - $r[2] or $cur.y >= $mon.y + $mon.lh - $r[3]) as $inBar
        | ([$mon.activeWorkspace.id] + (if ($mon.specialWorkspace.id // 0) != 0 then [$mon.specialWorkspace.id] else [] end)) as $visible
        | ($clients | map(select(
            .mapped and (.hidden | not) and (.workspace.id as $w | $visible | index($w) != null)
            and $cur.x >= .at[0] and $cur.x < .at[0] + .size[0]
            and $cur.y >= .at[1] and $cur.y < .at[1] + .size[1]
          )) | length) as $under
        | {monitor: $mon.name, workspace: $mon.activeWorkspace.id, onDesktop: (($inBar | not) and $under == 0)}
      end
  ' <<<"$mons"
}

# --- launching --------------------------------------------------------------

run_entry() { # <monitor> <entry-json>
  local mon="$1" entry="$2" kind id exec
  kind=$(jq -r '.kind' <<<"$entry")
  [[ -n $mon ]] && hyprctl dispatch focusmonitor "$mon" >/dev/null 2>&1
  case "$kind" in
    desktop)
      id=$(jq -r '.id' <<<"$entry")
      # Same path as the shell's own app launcher: gtk-launch resolves ids
      # uwsm rejects, inside a scope under app-graphical.slice.
      setsid -f uwsm-app -- gtk-launch "$id.desktop" >/dev/null 2>&1 </dev/null
      ;;
    command)
      exec=$(jq -r '.exec' <<<"$entry")
      # Through Hyprland's exec so a typed command behaves exactly like a
      # `bindd ... exec, <cmd>` line would.
      hyprctl dispatch exec "$exec" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

# --- picker -----------------------------------------------------------------

# Summon the overlay and act on its answer. Prints nothing; exit 1 on cancel.
pick() { # <ws> <monitor>
  local ws="$1" mon="$2" rows current_key payload selection_file done_file result action row

  # The overlay opens on the focused monitor; make that the clicked one.
  [[ -n $mon ]] && hyprctl dispatch focusmonitor "$mon" >/dev/null 2>&1
  snapshot_running
  rows=$(rows_for "$ws")
  current_key=$(state_read | jq -r --arg ws "$ws" '
    .defaults[$ws] | if . == null then "" elif .kind == "desktop" then "desktop:" + .id else "command:" + .exec end')

  selection_file=$(mktemp)
  done_file=$(mktemp)
  rm -f "$done_file"
  trap "rm -f '$selection_file' '$done_file'" EXIT

  payload=$(jq -nc --arg ws "$ws" --arg mon "$mon" --argjson rows "$rows" --arg key "$current_key" \
    --arg sel "$selection_file" --arg done "$done_file" \
    '{workspace: ($ws | tonumber), monitor: $mon, rows: $rows, currentKey: $key, selectionFile: $sel, doneFile: $done}')

  if [[ $(omarchy-shell shell summon "$PLUGIN_ID" "$payload" 2>/dev/null) != "ok" ]]; then
    notify-send -a workspace-app -u critical "Workspace app" "Picker plugin $PLUGIN_ID is not enabled"
    return 1
  fi

  while [[ ! -e $done_file ]]; do
    sleep 0.05
  done
  [[ -s $selection_file ]] || return 1

  result=$(cat "$selection_file")
  action=$(jq -r '.action // ""' <<<"$result")
  row=$(jq -c '.row // empty' <<<"$result")
  [[ -n $row ]] || return 1

  case "$action" in
    set)
      set_default "$ws" "$row"
      record_recent "$row" "$(date +%s)" 1
      run_entry "$mon" "$row"
      ;;
    test)
      record_recent "$row" "$(date +%s)" 1
      run_entry "$mon" "$row"
      ;;
    *)
      return 1
      ;;
  esac
}

click() { # launch|set
  local mode="$1" ctx ws mon entry
  ctx=$(cursor_context) || exit 1
  [[ $(jq -r '.onDesktop' <<<"$ctx") == "true" ]] || exit 0
  ws=$(jq -r '.workspace' <<<"$ctx")
  mon=$(jq -r '.monitor' <<<"$ctx")

  if [[ $mode == launch ]]; then
    entry=$(state_read | jq -c --arg ws "$ws" '.defaults[$ws] // empty')
    if [[ -n $entry ]]; then
      record_recent "$entry" "$(date +%s)" 1
      run_entry "$mon" "$entry"
      return
    fi
  fi
  pick "$ws" "$mon"
}

# --- main -------------------------------------------------------------------

case "${1:-}" in
  launch | set) click "$1" ;;
  rows)
    [[ ${2:-} =~ ^[0-9]+$ ]] || { echo "usage: workspace-app.sh rows <ws>" >&2; exit 1; }
    rows_for "$2"
    ;;
  forget)
    [[ -n ${2:-} ]] || { echo "usage: workspace-app.sh forget <key>" >&2; exit 1; }
    forget_key "$2"
    ;;
  run)
    [[ -n ${3:-} ]] || { echo "usage: workspace-app.sh run <monitor> <entry-json>" >&2; exit 1; }
    run_entry "$2" "$3"
    ;;
  resolve) resolve_class "${2:-}" ;;
  context) cursor_context ;;
  snapshot) snapshot_running ;;
  *)
    sed -n '2,20p' "$0" >&2
    exit 1
    ;;
esac
