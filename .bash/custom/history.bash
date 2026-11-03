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
# `h help` lists the h subcommands (swap/back: read-only switch to the history files found in a
# directory, remove to delete entries, file for status; each has a single-letter alias);
# `hh` creates local history files for every installed shell and switches HISTFILE for real.
# Ctrl+R fzf-searches the same merged shell-tagged view (bash-only in shell mode), read-only:
# picking an entry just puts it on the command line.
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

# Where a shell's history file lives right now, ignoring swaps and pins: ./.<shell>_history if
# scope is local, it exists and cwd != HOME, else the shell's global file (hist-merge's own rule)
_h_shells=(zsh bash fish)
_h_resolve() {
    local sh="${1}" scope_var="HISTORY_SCOPE_${1^^}" global="${HOME}/.${1}_history"
    [[ "${sh}" == "fish" ]] && global="${HOME}/.local/share/fish/fish_history"
    if [[ "${!scope_var:-${HISTORY_SCOPE:-local}}" == "local" && -f "${PWD}/.${sh}_history" && "${PWD}" != "${HOME}" ]]; then
        echo "${PWD}/.${sh}_history"
    else
        echo "${global}"
    fi
}

# If custom .bash_history in current folder respect it (unless scoped global)
HISTFILE="$(_h_resolve bash)"
_hist_apply_settings

# INC_APPEND_HISTORY + SHARE_HISTORY analog: append each command to HISTFILE immediately and
# pick up lines other bash sessions appended
if [[ "${PROMPT_COMMAND}" != *"history -a"* ]]; then
    PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND}; }history -a; history -n"
fi

# Files the merged view (and h rm, h file, Ctrl+R) look at, per shell; first match wins:
#   1. _h_swap_over  temporary override pushed by h swap, popped by h back
#   2. _h_pin        persistent override set by hh for the other shells' new local files
#   3. this shell's live file: _h_swap_view while h swap holds HISTFILE at /dev/null, else HISTFILE
#   4. _h_resolve    cwd/scope resolution
# Fills the _h_specs array. _h_swap_stack holds one record per active swap: first line
# '1<TAB>prev HISTFILE<TAB>prev view' if the swap replaced this shell's own history, else '0';
# the rest a snapshot of _h_swap_over before it. _h_swap_pushed counts the records that did.
declare -gA _h_swap_over _h_pin
declare -ga _h_swap_stack
_h_merge_specs() {
    local sh path
    _h_specs=()
    for sh in "${_h_shells[@]}"; do
        if [[ -n "${_h_swap_over[${sh}]:-}" ]]; then
            path="${_h_swap_over[${sh}]}"
        elif [[ -n "${_h_pin[${sh}]:-}" ]]; then
            path="${_h_pin[${sh}]}"
        elif [[ "${sh}" == "bash" ]]; then
            path="${_h_swap_view:-${HISTFILE:-${HOME}/.bash_history}}"
        else
            path="$(_h_resolve "${sh}")"
        fi
        _h_specs+=("${sh}:${path}")
    done
}

# h file (and the tail of h help): the current history file of each shell, as the merged view
# resolves them, with swap/pin status and a flag for files that don't exist yet
_h_files() {
    local _h_specs
    _h_merge_specs
    local spec sh path note
    for spec in "${_h_specs[@]}"; do
        sh="${spec%%:*}"
        path="${spec#*:}"
        note=""
        [[ "${sh}" == "bash" ]] && note="this shell"
        if [[ -n "${_h_swap_over[${sh}]:-}" || ( "${sh}" == "bash" && ${_h_swap_pushed:-0} -gt 0 ) ]]; then
            note+="${note:+; }swapped read-only: 'h back' returns"
        elif [[ -n "${_h_pin[${sh}]:-}" ]]; then
            note+="${note:+; }pinned by hh"
        fi
        [[ -f "${path}" ]] || note+="${note:+; }missing"
        printf '    %-5s %s%s\n' "${sh}:" "${path}" "${note:+ (${note})}"
    done
    (( ${#_h_swap_stack[@]} > 0 )) && echo "    (${#_h_swap_stack[@]} swap(s) active)"
    return 0
}

# h swap/back: read-only switch of the history files h looks at. Arguments: none (every history
# file in cwd), directories (every history file there), files (shell inferred from the name) or
# explicit shell:path specs. This shell's own file is loaded the way zsh's fc -p/-P stack works:
# flush pending lines, load the target into memory, point HISTFILE at /dev/null so the
# PROMPT_COMMAND history -a/-n writes nothing anywhere while swapped. The other shells' files
# only change the merged view. Ignores HISTORY_SCOPE: an explicit swap wins.
_h_swap_targets() {   # fills the caller's _h_want assoc (shell -> absolute path) from swap args
    local arg sh path dir
    for arg in "${@:-${PWD}}"; do
        if [[ -d "${arg}" ]]; then
            dir="$(cd "${arg}" && pwd)"
            for sh in "${_h_shells[@]}"; do
                [[ -f "${dir}/.${sh}_history" ]] && _h_want[${sh}]="${dir}/.${sh}_history"
            done
            continue
        fi
        if [[ "${arg}" =~ ^(zsh|bash|fish): ]]; then
            sh="${arg%%:*}"
            path="${arg#*:}"
        else
            path="${arg}"
            case "${path##*/}" in
                *zsh_history*)  sh=zsh ;;
                *bash_history*) sh=bash ;;
                *fish_history*) sh=fish ;;
                *)
                    echo "h swap: cannot tell which shell owns ${path}; use a zsh:/bash:/fish: prefix"
                    return 1 ;;
            esac
        fi
        if [[ ! -f "${path}" ]]; then
            echo "h swap: no history file at ${path} (hh creates real local history files)"
            return 1
        fi
        [[ "${path}" == /* ]] || path="${PWD}/${path}"
        _h_want[${sh}]="${path}"
    done
    if (( ${#_h_want[@]} == 0 )); then
        echo "h swap: no .zsh_history/.bash_history/.fish_history in ${*:-${PWD}}"
        return 1
    fi
    return 0
}

_h_swap() {
    local -A _h_want
    _h_swap_targets "$@" || return 1
    local record="0" sh
    for sh in "${!_h_swap_over[@]}"; do
        record+=$'\n'"${sh}"$'\t'"${_h_swap_over[${sh}]}"
    done
    for sh in "${_h_shells[@]}"; do
        [[ -n "${_h_want[${sh}]:-}" ]] || continue
        if [[ "${sh}" == "bash" ]]; then
            history -a
            record="1"$'\t'"${HISTFILE}"$'\t'"${_h_swap_view:-}${record#0}"
            _h_swap_view="${_h_want[bash]}"
            HISTFILE=/dev/null
            history -c
            history -r "${_h_swap_view}"
            _h_swap_pushed=$(( ${_h_swap_pushed:-0} + 1 ))
        else
            _h_swap_over[${sh}]="${_h_want[${sh}]}"
        fi
    done
    _h_swap_stack+=("${record}")
    echo "Swapped (read-only: commands typed now are saved nowhere; 'h back' returns):"
    _h_files
}

_h_back() {
    local depth=${#_h_swap_stack[@]}
    if (( depth == 0 )); then
        echo "h back: no swap active"
        return 1
    fi
    local record="${_h_swap_stack[depth-1]}"
    unset "_h_swap_stack[depth-1]"
    local -a lines
    mapfile -t lines <<< "${record}"
    local pushed prev_histfile prev_view
    IFS=$'\t' read -r pushed prev_histfile prev_view <<< "${lines[0]}"
    if [[ "${pushed}" == "1" ]]; then
        HISTFILE="${prev_histfile}"
        if [[ -n "${prev_view}" ]]; then
            _h_swap_view="${prev_view}"
        else
            unset _h_swap_view
        fi
        history -c
        history -r "${_h_swap_view:-${HISTFILE}}"
        _h_swap_pushed=$(( _h_swap_pushed - 1 ))
    fi
    _h_swap_over=()
    local line
    for line in "${lines[@]:1}"; do
        [[ -n "${line}" ]] || continue
        _h_swap_over[${line%%$'\t'*}]="${line#*$'\t'}"
    done
    echo "Back:"
    _h_files
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
    h s|swap [target ...]    switch to every history file found in cwd (or in the given
                             directories / the given files), read-only: nothing is written
                             to any history file until you swap back
    h b|back                 undo the last swap (commands typed while swapped are discarded)
    h f|file                 list each shell's current history file (and swap/pin status)
    h h|help | -h | --help   show this help message

Mode (HISTORY_MODE_BASH, then HISTORY_MODE; default agnostic):
agnostic = read-only merged view across zsh/bash/fish via hist-merge; shell = bash only

Notes:
    Delete several entries in one h remove call: the numbers shift after a deletion.
    h remove edits the files only; running shells may keep deleted entries in memory.
    h swap is the read-only counterpart of hh (which creates local history files for every
    installed shell and switches HISTFILE for real). Swap targets: .zsh_history,
    .bash_history, .fish_history in a directory, or files named like that, or shell:path.
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
        s|swap)      shift; _h_swap "$@"; return $? ;;
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

# hh: start local history files for every installed shell in cwd, each seeded with that shell's
# current history, and switch this shell's HISTFILE to its one for real. The other shells' files
# are pinned for the merged view and picked up by those shells when they start in this directory
# (HISTORY_SCOPE local). In $HOME: switch back to the global files and drop the pins instead.
hh_func() {
    usage() {
        cat <<EOF
Create ./.<shell>_history for every installed shell (zsh/bash/fish), seeded with that shell's
current history, and switch this shell's HISTFILE to ./.bash_history for real. Run in \$HOME to
switch back to the global files. h swap is the read-only counterpart.
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

    if (( ${#_h_swap_stack[@]} > 0 )); then
        echo "hh: a swap is active; run 'h back' first"
        return 1
    fi

    local -a shells
    local sh
    for sh in "${_h_shells[@]}"; do
        command -v "${sh}" > /dev/null && shells+=("${sh}")
    done

    local question
    if [[ "${PWD}" == "${HOME}" ]]; then
        question="Switch back to the global history files and drop hh pins?"
    else
        question="Create local history files in ${PWD} for ${shells[*]} and switch this shell's HISTFILE to ./.bash_history?"
    fi
    if ! ${auto_confirm}; then
        echo -n "${question} [y/N]: "
        read -r answer
        case "$answer" in
            [yY][eE][sS]|[yY]) ;;
            *)
                echo "Aborted."
                return 1
                ;;
        esac
    fi

    if [[ "${PWD}" == "${HOME}" ]]; then
        HISTFILE="${HOME}/.bash_history"
        _hist_apply_settings
        _h_pin=()
        echo "Back on the global history files:"
        _h_files
        return 0
    fi

    local src dst
    for sh in "${shells[@]}"; do
        dst="${PWD}/.${sh}_history"
        if [[ "${sh}" == "bash" ]]; then
            src="${HISTFILE}"
        elif [[ -n "${_h_pin[${sh}]:-}" ]]; then
            src="${_h_pin[${sh}]}"
        else
            src="$(_h_resolve "${sh}")"
        fi
        if [[ -f "${dst}" ]]; then
            echo "    ${sh}: ${dst} exists, kept"
        elif [[ -f "${src}" ]]; then
            cp "${src}" "${dst}"
            echo "    ${sh}: created ${dst} from ${src}"
        else
            : > "${dst}"
            echo "    ${sh}: created empty ${dst} (${src} does not exist)"
        fi
        if [[ "${sh}" == "bash" ]]; then
            HISTFILE="${dst}"
            _hist_apply_settings
        else
            _h_pin[${sh}]="${dst}"
        fi
    done
    echo "Current history files:"
    _h_files
}
alias hh='hh_func '
