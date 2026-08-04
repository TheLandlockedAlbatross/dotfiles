# Xmodmap custom key mappings
# (x11/ files are only sourced in X11 sessions — see .zshrc)
if command -v xmodmap &> /dev/null; then
    if [[ ! -f ~/.Xmodmap ]]; then
        xmodmap -pke > ~/.Xmodmap
    fi
    xmodmap ~/.Xmodmap
fi
