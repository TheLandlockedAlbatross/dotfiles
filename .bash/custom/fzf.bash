####################################################################################################
# fzf (bash port of ~/.zsh/custom/fzf.zsh)
####################################################################################################

# fix inconsisent naming of fd/fdfind
if [[ -n $(command -v fdfind) ]]; then
    alias fd='fdfind'
elif [[ -n $(command -v fd) ]]; then
    alias fdfind='fd'
fi

# regular options
export FZF_DEFAULT_OPTS="--multi \
--height=50% \
--margin=5%,2%,2%,5% \
--layout=reverse-list \
--border=double \
--info=inline \
--prompt='$>' \
--pointer='→' \
--marker='♡' \
--header='CTRL-c or ESC to quit' \
"
# nice color scheme generated with https://vitormv.github.io/fzf-themes/
export FZF_DEFAULT_OPTS=$FZF_DEFAULT_OPTS'
  --color=fg:#d0d0d0,fg+:#d0d0d0,bg:#121212,bg+:#262626
  --color=hl:#5f87af,hl+:#5fd7ff,info:#afaf87,marker:#87ff00
  --color=prompt:#d7005f,spinner:#af5fff,pointer:#af5fff,header:#87afaf
  --color=border:#262626,label:#aeaeae,query:#d9d9d9
  --border="rounded" --border-label="" --preview-window="border-rounded" --prompt="> "
  --marker=">" --pointer="◆" --separator="─" --scrollbar="│"'
# default commands
export FZF_DEFAULT_COMMAND='fd . --hidden'
# alias functions
# choose program to open result in
fzf_run() {
    # Usage: fzf_run [dir] [cmd...]
    local dir="."
    if [[ -d "${1}" ]]; then
        dir="${1}"
        shift
    fi
    local run="${*}" # Program to open result in, echo if no arg given

    # echo result and copy it to the clipboard (Wayland or X11)
    _fzf_run_copy() {
        if [[ -n "${WAYLAND_DISPLAY}" ]] && command -v wl-copy &> /dev/null; then
            printf '%s' "${res}" | wl-copy
            if [[ "$(wl-paste --no-newline 2> /dev/null)" == "${res}" ]]; then
                echo "\"${res}\" (copied to clipboard)"
            else
                echo "\"${res}\" (failed to copy to clipboard via wl-copy)"
            fi
        elif [[ -n "${DISPLAY}" ]] && command -v xsel &> /dev/null; then
            printf '%s' "${res}" | xsel --clipboard --input
            if [[ "$(xsel --clipboard --output)" == "${res}" ]]; then
                echo "\"${res}\" (copied to clipboard)"
            else
                echo "\"${res}\" (failed to copy to clipboard via xsel)"
            fi
        else
            echo "\"${res}\" (not copied: need wl-clipboard on Wayland or xsel on X11)"
        fi
    }

    local res=$(fd . "${dir}" -uHL | fzf)
    [[ -z "${res}" ]] && return
    res=$(realpath "${res}")

    if [[ -z "${run}" ]]; then
        # if no command, by default echo and copy to clipboard
        _fzf_run_copy
    elif ! command -v "${run%% *}" > /dev/null; then
        echo "command \"${run%% *}\" not found"
        # if bad command, by default echo and copy to clipboard
        _fzf_run_copy
    else
        echo "${run} \"${res}\""
        eval "${run} \"${res}\""
    fi
}
# aliases
alias f='fzf_run '
