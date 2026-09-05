#!/bin/bash
# Tailscale status: glyph reflects backend state, tooltip carries self IP,
# online peer count, and active exit node. Read-only; no click toggles so the
# tailnet (SSH, Serve, Funnel) can't be dropped by a stray click.
st=$(tailscale status --json 2>/dev/null)
if [[ -z "$st" ]]; then
  echo '{"text": "󰦞", "tooltip": "tailscaled not reachable", "class": "critical"}'
  exit 0
fi

jq -c '
  (.BackendState // "Unknown") as $state
  | ([.Peer[]? | select(.Online)] | length) as $online
  | ([.Peer[]? | select(.ExitNode) | .HostName] | first) as $exit
  | (.Self.TailscaleIPs[0] // "?") as $ip
  | if $state == "Running" then
      {
        text: "󰖂",
        tooltip: ("Tailscale up: \($ip)\n\($online) peers online" + (if $exit then "\nexit node: \($exit)" else "" end)),
        class: ""
      }
    else
      { text: "󰦞", tooltip: ("Tailscale: " + $state), class: "warning" }
    end' <<<"$st" 2>/dev/null
