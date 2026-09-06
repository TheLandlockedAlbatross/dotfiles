# have reset run zshrc to get any updates + a fetch banner (whichever is installed)
unalias r 2>/dev/null
r() {
    local keep_histfile="${HISTFILE}"
    reset
    { command -v fastfetch > /dev/null && fastfetch } || { command -v neofetch > /dev/null && neofetch }
    source "${HOME}/.zshrc"
    # A custom HISTFILE (hh pin, h swap, manual export) survives the re-source:
    # anything differing from the fresh resolution is treated as deliberate.
    if [[ -n "${keep_histfile}" && "${keep_histfile}" != "${HISTFILE}" ]]; then
        HISTFILE="${keep_histfile}"
    fi
    tput cuu1
}
