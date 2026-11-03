# o [path]: open the file manager at the current directory (or the given one;
# a file opens its folder). Fully detached: own session, no output in this
# terminal, and closing either side leaves the other running.
#
# Default is whatever the OS treats as its file browser:
#   macOS  -> open (Finder)
#   WSL    -> explorer.exe (Windows path via wslpath)
#   others -> xdg-open (the inode/directory default; change it with
#             `xdg-mime default <app>.desktop inode/directory`)
# Override with O_FILE_MANAGER, e.g. export O_FILE_MANAGER='thunar' or
# 'nautilus --new-window'; it is split into words and given the directory.
o() {
  local dir=${1:-$PWD}
  [[ -d $dir ]] || dir=${dir:h}
  dir=${dir:A}

  local -a cmd
  if [[ -n $O_FILE_MANAGER ]]; then
    cmd=(${(z)O_FILE_MANAGER})
  elif [[ $OSTYPE == darwin* ]]; then
    cmd=(open)
  elif [[ -n $WSL_DISTRO_NAME ]] && (( $+commands[explorer.exe] )); then
    cmd=(explorer.exe) dir=$(wslpath -w "$dir")
  elif (( $+commands[xdg-open] )); then
    cmd=(xdg-open)
  elif (( $+commands[gio] )); then
    cmd=(gio open)
  else
    print -u2 "o: no file manager found; set O_FILE_MANAGER"; return 1
  fi
  if ! (( $+commands[$cmd[1]] )); then
    print -u2 "o: '$cmd[1]' not found"; return 1
  fi

  if (( $+commands[setsid] )); then
    setsid -f "${cmd[@]}" "$dir" >/dev/null 2>&1 </dev/null
  else
    ("${cmd[@]}" "$dir" >/dev/null 2>&1 </dev/null &!)  # macOS has no setsid
  fi
}
