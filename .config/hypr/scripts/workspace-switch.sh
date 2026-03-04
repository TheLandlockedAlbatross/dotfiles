#!/bin/bash
TARGET=$1
PREV_FILE=/tmp/hypr-workspace-prev
CURRENT=$(hyprctl activeworkspace -j | jq .id)

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
