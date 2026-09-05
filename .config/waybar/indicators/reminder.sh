#!/bin/bash
# omarchy 4 bar indicator: pending reminder count from omarchy-reminder.
omarchy-reminder show --json 2>/dev/null | jq -c '
  if (.count // 0) > 0 then
    {text: "󰢌", tooltip: (.tooltip // "Reminder pending"), class: "active"}
  else
    {text: ""}
  end' 2>/dev/null || echo '{"text": ""}'
