#!/bin/bash
TARGET=$1
PREV_FILE=/tmp/hypr-workspace-prev
SPLIT_STATE=/tmp/hypr-workspace-split
CURRENT=$(hyprctl activeworkspace -j | jq .id)

# If workspace split is active, determine the correct monitor
SPLIT_DEST=""
if [[ -f $SPLIT_STATE ]]; then
  mode=$(cat "$SPLIT_STATE")
  monitors=$(hyprctl monitors -j | jq -r '[.[] | select(.disabled == false)] | sort_by(.id) | .[].name')
  mon_a=$(echo "$monitors" | head -1)
  mon_b=$(echo "$monitors" | sed -n '2p')

  if [[ -n $mon_b ]]; then
    if (( TARGET % 2 == 1 )); then
      [[ $mode == "normal" ]] && SPLIT_DEST="$mon_a" || SPLIT_DEST="$mon_b"
    else
      [[ $mode == "normal" ]] && SPLIT_DEST="$mon_b" || SPLIT_DEST="$mon_a"
    fi
  fi
fi

if [[ "$CURRENT" == "$TARGET" ]]; then
    # Toggle back
    PREV=$(cat "$PREV_FILE" 2>/dev/null)
    if [[ -n "$PREV" && "$PREV" != "$CURRENT" ]]; then
        echo "$CURRENT" > "$PREV_FILE"
        hyprctl dispatch workspace "$PREV"
    fi
else
    # Update prev only when both current and target have windows
    TGT_WINDOWS=$(hyprctl workspaces -j | jq ".[] | select(.id == $TARGET) | .windows // 0")
    CUR_WINDOWS=$(hyprctl workspaces -j | jq ".[] | select(.id == $CURRENT) | .windows // 0")
    [[ -z "$TGT_WINDOWS" ]] && TGT_WINDOWS=0
    [[ -z "$CUR_WINDOWS" ]] && CUR_WINDOWS=0
    if (( CUR_WINDOWS > 0 && TGT_WINDOWS > 0 )); then
        echo "$CURRENT" > "$PREV_FILE"
    fi
    hyprctl dispatch workspace "$TARGET"
fi

# Enforce split: move workspace to correct monitor after switching
if [[ -n $SPLIT_DEST ]]; then
  hyprctl dispatch moveworkspacetomonitor "$TARGET $SPLIT_DEST" >/dev/null 2>&1
  hyprctl dispatch focusmonitor "$SPLIT_DEST" >/dev/null 2>&1
fi
