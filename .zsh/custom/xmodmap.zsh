# Xmodmap
if [[ "${PLATFORM}" -eq "Linux" || "${PLATFORM}" -eq "WSL" ]]; then
    if [[ ! -f ~/.Xmodmap ]]; then
        xmodmap -pke > ~/.Xmodmap
    fi
    xmodmap ~/.Xmodmap
fi
