#!/bin/bash
# Claude/agent usage meter, fed by the omarchy 4 shell's agents service cache
# (the hidden shell keeps ~/.cache/omarchy/agent-usage fresh). Shows the
# fullest limit; tooltip lists them all with reset times.
LIMITS="$HOME/.cache/omarchy/agent-usage/claude-limits.json"

[[ -f "$LIMITS" ]] || { echo '{"text": ""}'; exit 0; }

# Hide when the cache is older than an hour (shell down or scans failing)
fetched=$(jq -r '.fetchedAtMs // 0' "$LIMITS" 2>/dev/null)
now_ms=$(( $(date +%s) * 1000 ))
(( now_ms - fetched < 3600000 )) || { echo '{"text": ""}'; exit 0; }

jq -c --arg glyph "󱚝" '
  (.limits // []) as $l
  | ([$l[].percent] | max // 0) as $max
  | (($max * 100) | round) as $pct
  | {
      text: ($glyph + " " + ($pct | tostring) + "%"),
      tooltip: ($l | map("\(.label): \((.percent * 100) | round)% (resets \(.resetsAt | sub("\\..*"; "") | sub("T"; " ")))") | join("\n")),
      class: (if $max >= 0.9 then "critical" elif $max >= 0.7 then "warning" else "" end)
    }' "$LIMITS" 2>/dev/null || echo '{"text": ""}'
