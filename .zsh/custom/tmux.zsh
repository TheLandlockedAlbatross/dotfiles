alias tm='tmux '
alias tn='tmux new -s '
alias tl='tmux list-sessions '
alias ta='tmux at -t '
alias tk='tmux kill-session -t '
alias tx='tmuxinator '
alias tf='tmuxinator-fzf-start '
# For some reason not default only in tmux unless explicitly defined (https://unix.stackexchange.com/a/538614)
bindkey \^K kill-line
