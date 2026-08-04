hms_to_ms() {
  local h m s ms
  IFS=':.' read -r h m s ms <<< "$1"
  # 10# forces base-10 so zero-padded fields like "08" aren't parsed as octal
  echo $(( (10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0})*1000 + 10#${ms:-0} ))
}
