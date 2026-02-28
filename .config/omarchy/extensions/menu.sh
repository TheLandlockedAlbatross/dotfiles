# Overwrite parts of the omarchy-menu with user-specific submenus.
# See $OMARCHY_PATH/bin/omarchy-menu for functions that can be overwritten.
#
# WARNING: Overwritten functions will obviously not be updated when Omarchy changes.

show_monitors_menu() {
  local active_count
  active_count=$(hyprctl monitors -j | jq '[.[] | select(.disabled == false)] | length')

  local options="󰔎  Toggle Monitor"
  if (( active_count >= 2 )); then
    options="$options\n󰍹  Configure Layout"
  else
    options="$options\n󰍹  Configure Layout (need 2+ displays)"
  fi
  options="$options\n󰏫  Edit Config"

  case $(menu "Monitors" "$options") in
  *Edit*) open_in_editor ~/.config/hypr/monitors.conf ;;
  *Toggle*) ~/.config/hypr/scripts/monitor-toggle.sh ;;
  *Configure*Layout*need*) swayosd-client --custom-icon dialog-information --custom-message "Need 2+ active monitors to configure layout" ;;
  *Configure*Layout*) ~/.config/hypr/scripts/monitor-configure.sh ;;
  *) back_to show_setup_menu ;;
  esac
}

show_vpn_menu() {
  local status options=""
  status=$(mullvad status)

  if echo "$status" | head -1 | grep -q Connected; then
    local relay country_code country_name
    relay=$(echo "$status" | grep Relay | tr -s " " | cut -d" " -f3)
    country_code=$(echo "$relay" | cut -d- -f1)
    country_name=$(mullvad relay list | grep -E "^\S" | grep "($country_code)" | head -1 | sed 's/ *(.*//;s/^ *//')
    options="  $country_name ($country_code)"
  else
    options="󰖪  Disconnected"
  fi

  # Add all countries (skip current if connected)
  while IFS= read -r line; do
    local code name
    code=$(echo "$line" | grep -oP '\(\K[^)]+')
    name=$(echo "$line" | sed 's/ *(.*//;s/^ *//')
    [[ "$code" == "$country_code" ]] && continue
    options="$options\n󰕥  $name ($code)"
  done < <(mullvad relay list | grep -E "^\S")

  local selected
  selected=$(menu "VPN" "$options")

  case "$selected" in
  *Disconnected*|""|CNCLD) back_to show_setup_menu ;;
  *"$country_name ($country_code)"*) back_to show_setup_menu ;;
  *)
    local sel_code
    sel_code=$(echo "$selected" | grep -oP '\(\K[^)]+')
    local sel_name
    sel_name=$(echo "$selected" | sed 's/^[^ ]* *//;s/ *(.*//')
    if [[ -n "$sel_code" ]]; then
      local swayosd="$HOME/.config/hypr/scripts/swayosd-focused.sh"
      "$swayosd" --custom-icon security-high --custom-message "Mullvad Connecting to $sel_name..."
      mullvad relay set location "$sel_code"
      if echo "$status" | head -1 | grep -q Connected; then
        mullvad reconnect
      else
        mullvad connect
      fi
      while ! mullvad status | head -1 | grep -q Connected; do sleep 0.5; done
      local S R
      S=$(mullvad status)
      R=$(echo "$S" | grep Relay | tr -s " " | cut -d" " -f3)
      "$swayosd" --custom-icon security-high --custom-message "Mullvad Connected to $sel_name ($R)"
    fi
    ;;
  esac
}

show_setup_menu() {
  local options="󰕾  Audio\n󰖩  Wifi\n󰂯  Bluetooth\n󱐋  Power Profile\n󰒲  System Sleep\n󰍹  Monitors"
  [ -f ~/.config/hypr/bindings.conf ] && options="$options\n󰌌  Keybindings"
  [ -f ~/.config/hypr/input.conf ] && options="$options\n󰌌  Input"
  options="$options\n󰱔  DNS\n󰕥  VPN\n󰒃  Security\n󰒓  Config"

  case $(menu "Setup" "$options") in
  *Audio*) omarchy-launch-audio ;;
  *Wifi*) omarchy-launch-wifi ;;
  *Bluetooth*) omarchy-launch-bluetooth ;;
  *Power*) show_setup_power_menu ;;
  *System*) show_setup_system_menu ;;
  *Monitors*) show_monitors_menu ;;
  *Keybindings*) open_in_editor ~/.config/hypr/bindings.conf ;;
  *Input*) open_in_editor ~/.config/hypr/input.conf ;;
  *DNS*) present_terminal omarchy-setup-dns ;;
  *VPN*) show_vpn_menu ;;
  *Security*) show_setup_security_menu ;;
  *Config*) show_setup_config_menu ;;
  *) show_main_menu ;;
  esac
}
