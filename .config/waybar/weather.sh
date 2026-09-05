#!/bin/bash
# Weather via wttr.in, honoring the same location state the omarchy 4 shell
# uses (~/.local/state/omarchy/settings/weather.json; empty = IP geolocation).
# Change location with omarchy-weather-location. Icons are emitted via \U
# escapes because literal private-use glyphs don't survive every editor.
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

code=$(jq -r '.current_condition[0].weatherCode // "113"' "$CACHE" 2>/dev/null)
case "$code" in
  113) cp='\U000F0599' ;;                                              # sunny
  116) cp='\U000F0595' ;;                                              # partly cloudy
  119|122) cp='\U000F0590' ;;                                          # cloudy
  143|248|260) cp='\U000F0591' ;;                                      # fog
  176|263|266|293|296|353) cp='\U000F0597' ;;                          # light rain
  299|302|305|308|356|359) cp='\U000F0596' ;;                          # heavy rain
  179|182|185|227|230|281|284|311|314|317|320|323|326|329|332|335|338|350|362|365|368|371|374|377) cp='\U000F0598' ;;  # snow/sleet
  200|386|389|392|395) cp='\U000F0593' ;;                              # thunder
  *) cp='\U000F0595' ;;
esac
icon=$(printf "$cp")

jq -c --arg icon "$icon" '
  .current_condition[0] as $c
  | (.nearest_area[0] | "\(.areaName[0].value), \(.region[0].value)") as $where
  | {
      text: ($icon + " " + $c.temp_F + "°"),
      tooltip: ($where + "\n" + ($c.weatherDesc[0].value | sub(" +$"; "")) + ", feels like " + $c.FeelsLikeF + "°F\nHumidity " + $c.humidity + "%, wind " + $c.windspeedMiles + " mph")
    }' "$CACHE" 2>/dev/null || echo '{"text": ""}'
