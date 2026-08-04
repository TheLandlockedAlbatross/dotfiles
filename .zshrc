#!/bin/zsh

####################################################################################################
# Preliminary
####################################################################################################
# If not running interactively, don't do anything
[[ "$-" != *i* ]] && return

ZSH_THEME="powerlevel10k/powerlevel10k"
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
    source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export ZSH="${HOME}/.zsh"
mkdir -p "${ZSH}"

####################################################################################################
# Plugins
####################################################################################################
mkdir -p "${ZSH}/plugins"
# znap
if [[ ! -f ${ZSH}/plugins/marlonrichert/znap/znap.zsh ]]; then
    git clone --depth 1 -- https://github.com/marlonrichert/zsh-snap.git "${ZSH}/plugins/marlonrichert/znap"
fi
source "${ZSH}/plugins/marlonrichert/znap/znap.zsh"

# powerlevel10k
if [[ ! -d ${ZSH}/themes/powerlevel10k ]]; then
    git clone --depth 1 -- https://github.com/romkatv/powerlevel10k.git "${ZSH}/themes/powerlevel10k/"
fi
source "${ZSH}/themes/powerlevel10k/powerlevel10k.zsh-theme"

#znap source marlonrichert/zsh-autocomplete

if [[ ! -d ${ZSH}/plugins/zsh-users/zsh-autosuggestions/ ]]; then
    git clone --depth 1 -- https://github.com/zsh-users/zsh-autosuggestions/ "${ZSH}/plugins/zsh-users/zsh-autosuggestions"
fi
znap source zsh-users/zsh-autosuggestions

if [[ ! -d ${ZSH}/plugins/zsh-users/zsh-syntax-highlighting/ ]]; then
    git clone --depth 1 -- https://github.com/zsh-users/zsh-syntax-highlighting/ "${ZSH}/plugins/zsh-users/zsh-syntax-highlighting"
fi
znap source zsh-users/zsh-syntax-highlighting

# if [[ ! -f ${ZSH}/plugins/zsh-users/zsh-autosuggestions/zsh-history-substring-search.zsh ]]; then
#     git clone --depth 1 -- https://github.com/zsh-users/zsh-history-substring-search/ "${ZSH}/plugins/zsh-users/zsh-history-substring-search"
# fi
# znap source zsh-users/zsh-history-substring-search

if [[ ! -d ${ZSH}/plugins/MichaelAquilina/zsh-you-should-use/ ]]; then
    git clone --depth 1 -- https://github.com/MichaelAquilina/zsh-you-should-use/ "${ZSH}/plugins/MichaelAquilina/zsh-you-should-use"
fi
znap source MichaelAquilina/zsh-you-should-use

if [[ ! -d ${ZSH}/plugins/agkozak/zsh-z/ ]]; then
    git clone --depth 1 -- https://github.com/agkozak/zsh-z "${ZSH}/plugins/agkozak/zsh-z"
fi
znap source agkozak/zsh-z

####################################################################################################
# Custom
####################################################################################################
export ZSH_CUSTOM="${ZSH}/custom"
mkdir -p "${ZSH_CUSTOM}"

# Get my custom aliases etc
#source <(cat "${ZSH}/custom/"*.zsh)
for config_file ($ZSH_CUSTOM/*.zsh(N)); do
    source "$config_file"
done

# X11-only scripts and env vars (skipped on Wayland/headless sessions)
if [[ -z "${WAYLAND_DISPLAY}" && "${XDG_SESSION_TYPE}" != "wayland" && -n "${DISPLAY}" ]]; then
    for config_file ($ZSH_CUSTOM/x11/*.zsh(N)); do
        source "$config_file"
    done
fi

# Speed up completion
autoload -Uz compinit && compinit -C

# Quick config editing
alias ze="${EDITOR} ~/.zshrc ${ZSH}"

####################################################################################################
# 3rd party scripts
####################################################################################################
# Cargo
if [[ -f "$HOME/.cargo/env" ]]; then
    source "$HOME/.cargo/env"
fi

# Go
if [[ -d /usr/local/go ]]; then
    # Set GOROOT
    export GOROOT=/usr/local/go
    # Set GOPATH
    export GOPATH=$HOME/go
    # Add Go binaries to the system path
    export PATH=$GOPATH/bin:$GOROOT/bin:$PATH
fi

# nvm
export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm

if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    # Remove Homebrew from PATH if present
    export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v 'linuxbrew' | tr '\n' ':' | sed 's/:$//')

    # Load Homebrew environment variables, but don't prepend to PATH
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv | grep -v '^export PATH=')"

    # Append Homebrew's bin directories to the end of PATH
    export PATH="$PATH:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin"
fi

#THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv &> /dev/null; then
    eval "$(pyenv init - zsh)"
    if pyenv commands | grep -q virtualenv-init; then
        eval "$(pyenv virtualenv-init -)"
    fi
fi
#eval "$(HISTFILE=${HISTFILE} atuin init zsh --disable-up-arrow)"


# uv
[[ -f "$HOME/.local/bin/env" ]] && . "$HOME/.local/bin/env"

# Android
[[ -d /opt/android-studio-for-platform/bin ]] && export PATH="$PATH:/opt/android-studio-for-platform/bin"
if [[ -d $HOME/Android/Sdk ]]; then
    export ANDROID_HOME=$HOME/Android/Sdk
    export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
    export PATH=$PATH:$ANDROID_HOME/platform-tools
fi
