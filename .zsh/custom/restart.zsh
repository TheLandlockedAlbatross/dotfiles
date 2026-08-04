# have reset run zshrc to get any updates + a fetch banner (whichever is installed)
alias r='reset ; { command -v fastfetch > /dev/null && fastfetch } || { command -v neofetch > /dev/null && neofetch } ; source ${HOME}/.zshrc ; tput cuu1'
