# https://unix.stackexchange.com/a/740599
# Enable Ctrl+arrow key bindings for word jumping
bindkey '^[[1;5C' forward-word            # Ctrl+Right
bindkey '^[[1;5D' backward-word           # Ctrl+Left
bindkey '^[[1;5D' backward-word  # Ctrl + Left Arrow
bindkey '^[[1;5A' history-search-backward   # Ctrl+Up
bindkey '^[[1;5B' history-search-forward    # Ctrl+Down
# bindkey '^[[1;5A' history-substring-search-up  # Ctrl+Up
# bindkey '^[[1;5B' history-substring-search-down  # Ctrl+Down

# Use vim word chars
export WORDCHARS='*?_-.[]~=&;!#$%^(){}<>'

