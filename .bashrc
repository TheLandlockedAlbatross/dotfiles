# If not running interactively, don't do anything (leave this at the top of this file)
[[ $- != *i* ]] && return

# All the default Omarchy aliases and functions
# (don't mess with these directly, just overwrite them here!)
source ~/.local/share/omarchy/default/bash/rc

# My custom aliases and functions (ports of ~/.zsh/custom); sourced after omarchy's rc so
# they can override its defaults (e.g. HISTSIZE)
for config_file in ~/.bash/custom/*.bash; do
    [[ -f "${config_file}" ]] && source "${config_file}"
done
unset config_file

# Add your own exports, aliases, and functions here.
#
# Make an alias for invoking commands you use constantly
# alias p='python'
