hms_to_ms() {
  local h m s ms
  IFS=':.' read -r h m s ms <<< "$1"
  echo $(( (h*3600 + m*60 + s)*1000 + ms ))
}

