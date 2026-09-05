#!/bin/bash
# omarchy 4 bar indicator: night light glyph while hyprsunset runs warm.
omarchy-toggle-nightlight --status 2>/dev/null | jq -c '
  if .enabled then
    {text: "󰔎", tooltip: "Night light on (\(.temperature)K)", class: "active"}
  else
    {text: ""}
  end' 2>/dev/null || echo '{"text": ""}'
