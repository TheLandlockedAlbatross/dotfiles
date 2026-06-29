####################################################################################################
# History
# Mostly based on tips from https://www.soberkoder.com/unlimited-bash-history/
####################################################################################################

# If custom ~/.zsh_history in current folder respect it
if [[ -f "$(pwd)/.zsh_history" && "$(pwd)" != "${HOME}" ]]; then
    HISTFILE="$(pwd)/.zsh_history"
else
    HISTFILE="$HOME/.zsh_history"
fi

# HISTFILE settings
HISTSIZE=10000000
SAVEHIST=10000000
setopt BANG_HIST                 # Treat the '!' character specially during expansion.
setopt EXTENDED_HISTORY          # Write the history file in the ":start:elapsed;command" format.
setopt INC_APPEND_HISTORY        # Write to the history file immediately, not when the shell exits.
setopt SHARE_HISTORY             # Share history between all sessions.
setopt HIST_EXPIRE_DUPS_FIRST    # Expire duplicate entries first when trimming history.
setopt HIST_IGNORE_DUPS          # Don't record an entry that was just recorded again.
setopt HIST_IGNORE_ALL_DUPS      # Delete old recorded entry if new entry is a duplicate.
setopt HIST_FIND_NO_DUPS         # Do not display a line previously found.
setopt HIST_IGNORE_SPACE         # Don't record an entry starting with a space.
setopt HIST_SAVE_NO_DUPS         # Don't write duplicate entries in the history file.
setopt HIST_REDUCE_BLANKS        # Remove superfluous blanks before recording entry.
setopt HIST_VERIFY               # Don't execute immediately upon history expansion.
setopt HIST_BEEP                 # Beep when accessing nonexistent history.
setopt APPEND_HISTORY
setopt INC_APPEND_HISTORY
setopt SHARE_HISTORY
# Ignore duplicates and erase any existing ones
setopt HIST_IGNORE_DUPS       # Do not record an entry that was just recorded again.
setopt HIST_IGNORE_ALL_DUPS   # Delete old recorded entry if new entry is a duplicate.
setopt HIST_EXPIRE_DUPS_FIRST

# fc aliases
h_func() {
    usage() {
            cat <<EOF
h: various fc aliases for convenience
USAGE:
    h
    h [text]
    h [number]
    h [number] .
    h [number] b
    h -h | --help

Options:
If passed nothing, print HISTFILE
If passed text, search for it in HISTFILE for with ripgrep
If passed number, print out that line # of HISTFILE
If passed number + '.', run command at that line number of HISTFILE
If passed number + '&', run command at that line number of HISTFILE in background
if passed -h, --help, show this help message
EOF
    }
    if [[ -n "${1}" ]]; then
        if [[ "${1}" == <-> ]]; then
            local res=$(fc -ln "${1}" "${1}")
            if [[ "${2}" == '.' ]]; then
                eval "${res}"
            elif [[ "${2}" == 'b' ]]; then
                eval "${res} &"
            elif [[ -z "${2}" ]]; then
                echo "${res}"
            else
                usage
            fi
        elif [[ "${1}" == '--help' || "${1}" == '-h' ]]; then
            usage
        else
            fc -lf 1 | rg "${1}"
        fi
    else
        fc -lf 1
    fi
}
alias h='h_func '

# quick way to start custom zsh history that has all of current history to start
hh_func() {

    usage() {
        cat <<EOF
Replace current HISTFILE with one in current directory $(pwd)
Usage: $0 [-y|-h]

Options:
-y, --yes\t\tAutomatically continue without prompting
-h, --help\t\tShow this help message and exit
EOF
    }

    # Default: do not auto-confirm
    auto_confirm=false

    # Parse arguments
    if [[ $# -gt 1 ]]; then
        usage
    fi

    if [[ $# -eq 1 ]]; then
        case "$1" in
            -y|--yes)
                auto_confirm=true
                ;;
            -h|--help)
                usage
                ;;
            *)
                usage
                ;;
        esac
    fi

    if ! $auto_confirm; then
        echo -n "Do you want to replace current HISTFILE with one in current directory? [y/N]: "
        read -r answer
        case "$answer" in
            [yY][eE][sS]|[yY])
                OLD_HISTFILE="${HISTFILE}"
                HISTFILE="$(pwd)/.zsh_history"
                if [[ ! -f "$(pwd)/.zsh_history" && "$(pwd)" != "${HOME}" ]]; then
                    cat "${OLD_HISTFILE}" > "${HISTFILE}"
                fi
                HISTSIZE=10000000
                SAVEHIST=10000000
                setopt BANG_HIST                 # Treat the '!' character specially during expansion.
                setopt EXTENDED_HISTORY          # Write the history file in the ":start:elapsed;command" format.
                setopt INC_APPEND_HISTORY        # Write to the history file immediately, not when the shell exits.
                setopt SHARE_HISTORY             # Share history between all sessions.
                setopt HIST_EXPIRE_DUPS_FIRST    # Expire duplicate entries first when trimming history.
                setopt HIST_IGNORE_DUPS          # Don't record an entry that was just recorded again.
                setopt HIST_IGNORE_ALL_DUPS      # Delete old recorded entry if new entry is a duplicate.
                setopt HIST_FIND_NO_DUPS         # Do not display a line previously found.
                setopt HIST_IGNORE_SPACE         # Don't record an entry starting with a space.
                setopt HIST_SAVE_NO_DUPS         # Don't write duplicate entries in the history file.
                setopt HIST_REDUCE_BLANKS        # Remove superfluous blanks before recording entry.
                setopt HIST_VERIFY               # Don't execute immediately upon history expansion.
                setopt HIST_BEEP                 # Beep when accessing nonexistent history.
                setopt APPEND_HISTORY
                setopt INC_APPEND_HISTORY
                setopt SHARE_HISTORY
                # Ignore duplicates and erase any existing ones
                setopt HIST_IGNORE_DUPS       # Do not record an entry that was just recorded again.
                setopt HIST_IGNORE_ALL_DUPS   # Delete old recorded entry if new entry is a duplicate.
                setopt HIST_EXPIRE_DUPS_FIRST

                echo "Switched HISTFILE to ${HISTFILE} from ${OLD_HISTFILE}"
                ;;
            *)
                echo "Aborted."
                ;;
        esac
    else
        OLD_HISTFILE="${HISTFILE}"
        HISTFILE="$(pwd)/.zsh_history"
        if [[ ! -f "$(pwd)/.zsh_history" && "$(pwd)" != "${HOME}" ]]; then
            cat "${OLD_HISTFILE}" > "${HISTFILE}"
        fi
        HISTSIZE=10000000
        SAVEHIST=10000000
        setopt BANG_HIST                 # Treat the '!' character specially during expansion.
        setopt EXTENDED_HISTORY          # Write the history file in the ":start:elapsed;command" format.
        setopt INC_APPEND_HISTORY        # Write to the history file immediately, not when the shell exits.
        setopt SHARE_HISTORY             # Share history between all sessions.
        setopt HIST_EXPIRE_DUPS_FIRST    # Expire duplicate entries first when trimming history.
        setopt HIST_IGNORE_DUPS          # Don't record an entry that was just recorded again.
        setopt HIST_IGNORE_ALL_DUPS      # Delete old recorded entry if new entry is a duplicate.
        setopt HIST_FIND_NO_DUPS         # Do not display a line previously found.
        setopt HIST_IGNORE_SPACE         # Don't record an entry starting with a space.
        setopt HIST_SAVE_NO_DUPS         # Don't write duplicate entries in the history file.
        setopt HIST_REDUCE_BLANKS        # Remove superfluous blanks before recording entry.
        setopt HIST_VERIFY               # Don't execute immediately upon history expansion.
        setopt HIST_BEEP                 # Beep when accessing nonexistent history.
        setopt APPEND_HISTORY
        setopt INC_APPEND_HISTORY
        setopt SHARE_HISTORY
        # Ignore duplicates and erase any existing ones
        setopt HIST_IGNORE_DUPS       # Do not record an entry that was just recorded again.
        setopt HIST_IGNORE_ALL_DUPS   # Delete old recorded entry if new entry is a duplicate.
        setopt HIST_EXPIRE_DUPS_FIRST

        echo "Switched HISTFILE to ${HISTFILE} from ${OLD_HISTFILE}"
    fi


}
alias hh='hh_func '

# History search bindings
autoload -U up-line-or-beginning-search
autoload -U down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
# bindkey "^[[1;5A" up-line-or-beginning-search # Ctrl+Up
# bindkey "^[[1;5B" down-line-or-beginning-search # Ctrl+Down
