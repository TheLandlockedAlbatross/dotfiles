# atuin-search widget only exists once `atuin init zsh` has been eval'd
if (( ${+widgets[atuin-search]} )); then
    bindkey '^[[1;2A' atuin-search
fi
