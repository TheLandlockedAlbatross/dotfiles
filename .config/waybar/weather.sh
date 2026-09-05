#!/bin/bash
# Weather via wttr.in, honoring the same location state the omarchy 4 shell
# uses (~/.local/state/omarchy/settings/weather.json; empty = IP geolocation).
# Change location with omarchy-weather-location.
LOC_FILE="$HOME/.local/state/omarchy/settings/weather.json"
CACHE="$HOME/.cache/waybar-weather.json"

loc=""
if [[ -f "$LOC_FILE" ]]; then
  loc=$(jq -r 'if .latitude and .longitude then "\(.latitude),\(.longitude)" else (.name // "") end' "$LOC_FILE" 2>/dev/null)
fi

fresh=$(curl -sf --max-time 10 "https://wttr.in/${loc}?format=j1" 2>/dev/null)
if [[ -n "$fresh" ]] && jq -e '.current_condition[0]' <<<"$fresh" >/dev/null 2>&1; then
  printf '%s' "$fresh" > "$CACHE"
fi

[[ -s "$CACHE" ]] || { echo '{"text": ""}'; exit 0; }

jq -c '
  .current_condition[0] as $c
  | ($c.weatherCode // "113") as $code
  | ({
      "113": "", "116": "", "119": "", "122": "",
      "143": "", "248": "", "260": "",
      "176": "", "263": "", "266": "", "293": "", "296": "",
      "299": "", "302": "", "305": "", "308": "", "353": "", "356": "",
      "179": "", "227": "", "230": "", "323": "", "326": "", "329": "",
      "332": "", "335": "", "338": "", "368": "", "371": "",
      "200": "", "386": "", "389": "", "392": "", "395": ""
    }[$code] // "") as $icon
  | (.nearest_area[0] | "\(.areaName[0].value), \(.region[0].value)") as $where
  | {
      text: ($icon + " " + $c.temp_F + "°"),
      tooltip: ($where + "\n" + $c.weatherDesc[0].value + ", feels like " + $c.FeelsLikeF + "°F\nHumidity " + $c.humidity + "%, wind " + $c.windspeedMiles + " mph")
    }' "$CACHE" 2>/dev/null || echo '{"text": ""}'
