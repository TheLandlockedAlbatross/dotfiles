# fp auto-completion
() {
  # A list of each flatpak app name in lowercase.
  # (First word of the name to be exact, so "Brave Browser" will be "brave").
  local FLATPAK_APPS=$(flatpak list --app | cut -f1 | awk '{print tolower($1)}')
  complete -W $FLATPAK_APPS fp
}

# Run Flatpak apps from CLI, e.g.: "fp okular"
function fp() {
  app=$(flatpak list --app | cut -f2 | awk -v app="$1" '(tolower($NF) ~ tolower(app))')

  # Abort if the app name was not entered
  test -z $1 && printf "Enter an app to fp.\n\$ fp <app>\n\nINSTALLED APPS\n$app\n" && return;

  # Remove app name from "$@" array
  shift 1;

  # Run the flatpak app asynchronous and don't show any stdout and stderr
  ( flatpak run "$app" "$@" &> /dev/null & )
}

