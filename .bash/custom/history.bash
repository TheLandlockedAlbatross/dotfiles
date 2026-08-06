####################################################################################################
# History (bash port of ~/.zsh/custom/history.zsh)
# Mostly based on tips from https://www.soberkoder.com/unlimited-bash-history/
#
# Env vars (per-shell override wins over the global one):
#   HISTORY_MODE / HISTORY_MODE_BASH = agnostic (default) | shell
#       agnostic: `h` reports a merged, time-ordered, shell-tagged view across zsh/bash/fish
#                 via ~/.config/shell/hist-merge (read-only; no history files are modified)
#       shell:    `h` reports only bash's own history
#   HISTORY_SCOPE / HISTORY_SCOPE_BASH = local (default) | global
#       local:  use ./.bash_history if it exists and cwd != HOME, else ~/.bash_history
#       global: always ~/.bash_history
####################################################################################################

# Shared HISTFILE settings, applied at startup and by hh when switching HISTFILE
# (must run after omarchy's default/bash/shell, which sets HISTSIZE=32768 etc)
_hist_apply_settings() {
    HISTSIZE=10000000
    HISTFILESIZE=10000000                # SAVEHIST analog
    HISTCONTROL=ignoreboth:erasedups     # HIST_IGNORE_DUPS + HIST_IGNORE_SPACE + HIST_IGNORE_ALL_DUPS
    HISTTIMEFORMAT='%F %T '              # EXTENDED_HISTORY analog: writes #<epoch> lines to HISTFILE
    shopt -s histappend                  # APPEND_HISTORY
    shopt -s histverify                  # HIST_VERIFY: don't execute immediately upon history expansion
    shopt -s cmdhist                     # store multi-line commands as one entry
}

# If custom .bash_history in current folder respect it (unless scoped global)
if [[ "${HISTORY_SCOPE_BASH:-${HISTORY_SCOPE:-local}}" == "local" && -f "${PWD}/.bash_history" && "${PWD}" != "${HOME}" ]]; then
    HISTFILE="${PWD}/.bash_history"
else
    HISTFILE="${HOME}/.bash_history"
fi
_hist_apply_settings

# INC_APPEND_HISTORY + SHARE_HISTORY analog: append each command to HISTFILE immediately and
# pick up lines other bash sessions appended
if [[ "${PROMPT_COMMAND}" != *"history -a"* ]]; then
    PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND}; }history -a; history -n"
fi

# history aliases
h_func() {
    usage() {
            cat <<EOF
h: various history aliases for convenience
USAGE:
    h
    h [text]
    h [number]
    h [number] .
    h [number] b
    h -h | --help

Options:
If passed nothing, print history
If passed text, search for it in history with ripgrep
If passed number, print out that entry of history
If passed number + '.', run command at that entry of history
If passed number + 'b', run command at that entry of history in background
if passed -h, --help, show this help message

Mode (HISTORY_MODE_BASH, then HISTORY_MODE; default agnostic):
agnostic = read-only merged view across zsh/bash/fish via hist-merge; shell = bash only
EOF
    }
    local mode="${HISTORY_MODE_BASH:-${HISTORY_MODE:-agnostic}}"
    local merge="${HOME}/.config/shell/hist-merge"
    [[ -x "${merge}" ]] || mode="shell"
    if [[ -n "${1}" ]]; then
        if [[ "${1}" =~ ^[0-9]+$ ]]; then
            local res
            if [[ "${mode}" == "agnostic" ]]; then
                res=$("${merge}" --raw "${1}")
            else
                res=$(fc -ln "${1}" "${1}")
            fi
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
            if [[ "${mode}" == "agnostic" ]]; then
                "${merge}" | rg "${1}"
            else
                history | rg "${1}"
            fi
        fi
    else
        if [[ "${mode}" == "agnostic" ]]; then
            "${merge}"
        else
            history
        fi
    fi
}
alias h='h_func '

# quick way to start custom bash history that has all of current history to start
hh_func() {
    usage() {
        cat <<EOF
Replace current HISTFILE with one in current directory $(pwd)
Usage: hh [-y|-h]

Options:
EOF
        printf -- '-y, --yes\t\tAutomatically continue without prompting\n'
        printf -- '-h, --help\t\tShow this help message and exit\n'
    }

    # Default: do not auto-confirm
    local auto_confirm=false

    # Parse arguments
    if [[ $# -gt 1 ]]; then
        usage
        return 1
    fi
    if [[ $# -eq 1 ]]; then
        case "$1" in
            -y|--yes)
                auto_confirm=true
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                usage
                return 1
                ;;
        esac
    fi

    if ! ${auto_confirm}; then
        echo -n "Do you want to replace current HISTFILE with one in current directory? [y/N]: "
        read -r answer
        case "$answer" in
            [yY][eE][sS]|[yY]) ;;
            *)
                echo "Aborted."
                return 1
                ;;
        esac
    fi

    local OLD_HISTFILE="${HISTFILE}"
    HISTFILE="$(pwd)/.bash_history"
    if [[ ! -f "${HISTFILE}" && "$(pwd)" != "${HOME}" ]]; then
        cat "${OLD_HISTFILE}" > "${HISTFILE}"
    fi
    _hist_apply_settings
    echo "Switched HISTFILE to ${HISTFILE} from ${OLD_HISTFILE}"
}
alias hh='hh_func '
