#!/bin/bash
TARGET="$1"
[[ $TARGET =~ ^[0-9]+$ ]] || exit 1
PREV_FILE=/tmp/hypr-workspace-prev
MONS_JSON=$(hyprctl monitors -j)
read -r FOCUSED_MON CURRENT < <(jq -r '.[] | select(.focused) | "\(.name) \(.activeWorkspace.id)"' <<<"$MONS_JSON")

# Self-heal: monitor drops scatter workspaces onto surviving monitors and they
# never move back on their own. Re-home the target to its rule monitor first.
RULE_MON=$(hyprctl -j workspacerules | jq -r --argjson ws "$TARGET" '
  [ .[] | select(.monitor) | select(
      ((.workspaceString | test("^[0-9]+$")) and ((.workspaceString | tonumber) == $ws))
      or
      ((.workspaceString | test("^r\\[[0-9]+-[0-9]+\\]$")) and
       ((.workspaceString | capture("r\\[(?<a>[0-9]+)-(?<b>[0-9]+)\\]")) |
        ((.a | tonumber) <= $ws and $ws <= (.b | tonumber))))
    ) | .monitor ] | first // empty')
CUR_MON=$(hyprctl workspaces -j | jq -r ".[] | select(.id == $TARGET) | .monitor")
if [[ -n $RULE_MON && -n $CUR_MON && $RULE_MON != "$CUR_MON" ]]; then
    hyprctl dispatch moveworkspacetomonitor "$TARGET" "$RULE_MON" >/dev/null
fi

# Pre-switch workspace background (if feature is active)
WS_BG_MAP="/tmp/hypr-workspace-bg-map"
if [[ -f $WS_BG_MAP ]]; then
  if [[ "$CURRENT" == "$TARGET" ]]; then
    PREV=$(cat "$PREV_FILE" 2>/dev/null)
    [[ -n $PREV ]] && BG_TARGET="$PREV" || BG_TARGET="$TARGET"
  else
    BG_TARGET="$TARGET"
  fi
  BG=$(sed -n "${BG_TARGET}p" "$WS_BG_MAP")
  BG_MON="$FOCUSED_MON"
  if [[ -n $BG && -n $BG_MON ]]; then
    # Layout-aware paint (spans/pan/zoom); raw awww when no layout exists.
    source "$(dirname "$0")/bg-paint.lib.sh"
    BG_MONITORS_JSON="$MONS_JSON" bg_paint "$BG_MON" "$BG"
    sleep "$(cat /tmp/hypr-workspace-bg-framedur 2>/dev/null || echo 0.03)"
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
