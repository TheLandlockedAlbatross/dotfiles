####################################################################################################
# fzf
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
    local dir="${1:-.}"  # Default to current directory if no argument is given
    if [[ ! -d "${dir}" ]]; then
        dir="."
    fi
    if [[ $# > 1 ]]; then
        shift
    fi
    local run="${@}" # Program to open result in, echo if no arg given
    local res=$(fd . "${dir}" -uHL | fzf)
    res=$(realpath "${res}")

    if [[ -n ${res} ]]; then
        if [[ -z "${run}" ]]; then
            # if no command, by default echo and copy to clipboard
            printf "\"${res}\"" | xsel --clipboard --input
            if [[ "$(xsel --clipboard --output)" == "${res}" ]]; then
                echo "\"${res}\" (copied to clipboard)"
            else
                echo "\"${res}\" (somehow failed to copy to clipboard, maybe no xsel?)"
            fi
        elif [[ ! -n $(command -v ${run%% *}) ]]; then
            echo "command \"${run%% *}\" not found"
            # if bad command, by default echo and copy to clipboard
            printf "\"${res}\"" | xsel --clipboard --input
            if [[ "$(xsel --clipboard --output)" == "${res}" ]]; then
                echo "\"${res}\" (copied to clipboard)"
            else
                echo "\"${res}\" (somehow failed to copy to clipboard, maybe no xsel?)"
            fi
        else
            echo "${run} \"${res}\""
            ${run} "${res}"
        fi
    fi
}
fzf_vim() {
    local dir="${1:-.}"  # Default to current directory if no argument is given
    vim $(fd . "${dir}" --hidden | fzf)
}
# aliases
alias f='fzf_run '
alias vf='fzf_vim '
