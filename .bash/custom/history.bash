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
#
# `h help` lists the h subcommands (swap/back to a directory's HISTFILE without writing to any
# history file, remove to delete entries, file for status; each has a single-letter alias);
# `hh` switches HISTFILE for real. Ctrl+R fzf-searches the same merged shell-tagged view
# (bash-only in shell mode), read-only: picking an entry just puts it on the command line.
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

# Files the merged view (and h rm) should look at: bash's is the live one (so h swap/hh are
# reflected); zsh/fish mirror hist-merge's own env-var resolution. Fills the _h_specs array.
_h_merge_specs() {
    local zscope="${HISTORY_SCOPE_ZSH:-${HISTORY_SCOPE:-local}}"
    local zfile="${HOME}/.zsh_history"
    [[ "${zscope}" == "local" && -f "${PWD}/.zsh_history" && "${PWD}" != "${HOME}" ]] && zfile="${PWD}/.zsh_history"
    _h_specs=("zsh:${zfile}" "bash:${_h_swap_view:-${HISTFILE:-${HOME}/.bash_history}}" "fish:${HOME}/.local/share/fish/fish_history")
}

# h file (and the tail of h help): the current history file of each shell, as the merged view
# resolves them, with swap status for this shell and a flag for files that don't exist yet
_h_files() {
    local _h_specs
    _h_merge_specs
    local spec sh path note
    for spec in "${_h_specs[@]}"; do
        sh="${spec%%:*}"
        path="${spec#*:}"
        note=""
        if [[ "${sh}" == "bash" ]]; then
            note="this shell"
            (( ${#_h_swap_prev_histfile[@]} > 0 )) && note+="; swapped read-only, depth ${#_h_swap_prev_histfile[@]}: 'h back' returns"
        fi
        [[ -f "${path}" ]] || note+="${note:+; }missing"
        printf '    %-5s %s%s\n' "${sh}:" "${path}" "${note:+ (${note})}"
    done
}

# h swap/back: read-only HISTFILE switch (emulates zsh's fc -p/-P history stack). Flushes
# pending lines, loads the target into memory, and points HISTFILE at /dev/null so the
# PROMPT_COMMAND history -a/-n writes nothing anywhere while swapped.
_h_swap_prev_histfile=()
_h_swap_prev_view=()
_h_swap() {
    local target="${1:-${PWD}/.bash_history}"
    if [[ ! -f "${target}" ]]; then
        echo "h swap: no history file at ${target} (hh creates a real local HISTFILE)"
        return 1
    fi
    history -a
    _h_swap_prev_histfile+=("${HISTFILE}")
    _h_swap_prev_view+=("${_h_swap_view:-${HISTFILE}}")
    _h_swap_view="${target}"
    HISTFILE=/dev/null
    history -c
    history -r "${target}"
    echo "Swapped to ${target} (read-only: commands typed now are saved nowhere). 'h back' returns."
}

_h_back() {
    local depth=${#_h_swap_prev_histfile[@]}
    if (( depth == 0 )); then
        echo "h back: no swap active"
        return 1
    fi
    HISTFILE="${_h_swap_prev_histfile[depth-1]}"
    _h_swap_view="${_h_swap_prev_view[depth-1]}"
    unset "_h_swap_prev_histfile[depth-1]" "_h_swap_prev_view[depth-1]"
    history -c
    history -r "${_h_swap_view}"
    local extra=""
    if (( ${#_h_swap_prev_histfile[@]} == 0 )); then
        unset _h_swap_view
    else
        extra=" (still ${#_h_swap_prev_histfile[@]} swap(s) deep)"
    fi
    echo "Back on ${_h_swap_view:-${HISTFILE}}${extra}"
}

# h remove: delete history entries, addressed by the numbers h displays. Edits the history files
# (agnostic mode can hit zsh/bash/fish files via hist-merge --lines; shell mode also drops the
# entry from this session's memory). Other running shells may still hold deleted entries.
_h_rm() {
    local mode="${HISTORY_MODE_BASH:-${HISTORY_MODE:-agnostic}}"
    local merge="${HOME}/.config/shell/hist-merge"
    [[ -x "${merge}" ]] || mode="shell"
    if (( $# == 0 )); then
        echo "h remove: pass one or more entry numbers (as shown by h)"
        return 1
    fi
    local n
    for n in "$@"; do
        if ! [[ "${n}" =~ ^[0-9]+$ ]]; then
            echo "h remove: '${n}' is not an entry number"
            return 1
        fi
    done
    local fish_hit=0 deleted=0
    if [[ "${mode}" == "agnostic" ]]; then
        local _h_specs joined
        _h_merge_specs
        joined="$(IFS=,; echo "$*")"
        local out
        out="$("${merge}" --lines "${joined}" "${_h_specs[@]}")"
        local -A ranges found
        local num file s e c
        while IFS=$'\t' read -r num file s e c; do
            [[ -n "${num}" ]] || continue
            found[${num}]=1
            ranges[${file}]+="${s},${e}d;"
            [[ "${file}" == *fish_history ]] && fish_hit=1
            echo "rm ${num}: [${file/#${HOME}/\~}] ${c}"
        done <<< "${out}"
        for n in "$@"; do
            [[ -n "${found[${n}]:-}" ]] || echo "h remove: no entry ${n}"
        done
        (( ${#ranges[@]} )) || return 1
        for file in "${!ranges[@]}"; do
            sed -i "${ranges[${file}]%;}" "${file}"
        done
        deleted=1
    else
        # Descending order so history -d doesn't shift the numbers still to be deleted
        local text range histfile="${_h_swap_view:-${HISTFILE}}"
        for n in $(printf '%s\n' "$@" | sort -rnu); do
            text="$(fc -ln "${n}" "${n}" 2>/dev/null)"
            if [[ -z "${text}" ]]; then
                echo "h remove: no entry ${n}"
                continue
            fi
            # Last file line matching the entry's text (whitespace-trimmed), plus its #<epoch> line
            range="$(TARGET="${text}" awk '
                function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
                BEGIN { t = trim(ENVIRON["TARGET"]) }
                {
                    if ($0 ~ /^#[0-9]+$/) {
                        pendline = NR
                    } else {
                        if (trim($0) == t) { ms = (pendline ? pendline : NR); me = NR }
                        pendline = 0
                    }
                }
                END { if (ms) print ms "," me }
            ' "${histfile}")"
            echo "rm ${n}: ${text#"${text%%[![:space:]]*}"}"
            history -d "${n}"
            deleted=1
            if [[ -n "${range}" ]]; then
                sed -i "${range}d" "${histfile}"
            else
                echo "h remove: entry ${n} not found in ${histfile} (removed from session memory only)"
            fi
        done
    fi
    (( deleted )) && echo "(files updated; running shells may still hold deleted entries in memory)"
    (( fish_hit )) && echo "(fish rewrites its own file: fish entries can come back until fish restarts)"
    return 0
}

# history aliases
h_func() {
    usage() {
            cat <<EOF
h: various history helpers
USAGE:
    h                        list history
    h [text]                 search history with ripgrep
    h [number]               print that history entry
    h [number] .             run that history entry
    h [number] b             run that history entry in background
    h r|remove <n> [<n>...]  delete entries (numbers as shown by h) from their history files
    h s|swap [file]          switch to ./.bash_history (or file), read-only: nothing is
                             written to any history file until you swap back
    h b|back                 undo the last swap (commands typed while swapped are discarded)
    h f|file                 list each shell's current history file (and swap status)
    h h|help | -h | --help   show this help message

Mode (HISTORY_MODE_BASH, then HISTORY_MODE; default agnostic):
agnostic = read-only merged view across zsh/bash/fish via hist-merge; shell = bash only

Notes:
    Delete several entries in one h remove call: the numbers shift after a deletion.
    h remove edits the files only; running shells may keep deleted entries in memory.
    h swap is the read-only counterpart of hh (which switches HISTFILE for real).
    The subcommand words and letters are reserved; to search one literally: h '(swap)'

Current history files:
EOF
            _h_files
    }
    local mode="${HISTORY_MODE_BASH:-${HISTORY_MODE:-agnostic}}"
    local merge="${HOME}/.config/shell/hist-merge"
    [[ -x "${merge}" ]] || mode="shell"
    case "${1}" in
        h|help|-h|--help) usage; return 0 ;;
        r|rm|remove) shift; _h_rm "$@"; return $? ;;
        s|swap)      _h_swap "${2}"; return $? ;;
        b|back)      _h_back; return $? ;;
        f|file) _h_files; return 0 ;;
    esac
    local _h_specs
    _h_merge_specs
    if [[ -n "${1}" ]]; then
        if [[ "${1}" =~ ^[0-9]+$ ]]; then
            local res
            if [[ "${mode}" == "agnostic" ]]; then
                res=$("${merge}" --raw "${1}" "${_h_specs[@]}")
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
        else
            if [[ "${mode}" == "agnostic" ]]; then
                "${merge}" "${_h_specs[@]}" | rg "${1}"
            else
                history | rg "${1}"
            fi
        fi
    else
        if [[ "${mode}" == "agnostic" ]]; then
            "${merge}" "${_h_specs[@]}"
        else
            history
        fi
    fi
}
alias h='h_func '

# Ctrl+R: fzf over the merged, shell-tagged history (agnostic mode; same files h uses, so
# swaps and local HISTFILEs are respected). Read-only: picking an entry only puts it on the
# command line. Shell mode falls back to the stock bash-only fzf widget omarchy sourced.
_h_fzf_search() {
    local mode="${HISTORY_MODE_BASH:-${HISTORY_MODE:-agnostic}}"
    local merge="${HOME}/.config/shell/hist-merge"
    [[ -x "${merge}" ]] || mode="shell"
    if [[ "${mode}" != "agnostic" ]]; then
        declare -F __fzf_history__ > /dev/null && __fzf_history__
        return
    fi
    local _h_specs selection num
    _h_merge_specs
    selection="$("${merge}" "${_h_specs[@]}" | tac \
        | fzf --no-multi --scheme=history --query="${READLINE_LINE}" \
              --header='merged zsh/bash/fish history (read-only)')" || return
    num="${selection#"${selection%%[0-9]*}"}"
    num="${num%%[^0-9]*}"
    [[ -n "${num}" ]] || return
    READLINE_LINE="$("${merge}" --raw "${num}" "${_h_specs[@]}")"
    READLINE_POINT=${#READLINE_LINE}
}
# Rebind after omarchy's fzf key-bindings.bash claimed Ctrl+R for bash-only history
if [[ $- == *i* ]] && command -v fzf > /dev/null; then
    bind -x '"\C-r": _h_fzf_search'
fi

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
