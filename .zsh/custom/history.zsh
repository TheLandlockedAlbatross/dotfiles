####################################################################################################
# History
# Mostly based on tips from https://www.soberkoder.com/unlimited-bash-history/
#
# Env vars (per-shell override wins over the global one):
#   HISTORY_MODE / HISTORY_MODE_ZSH = agnostic (default) | shell
#       agnostic: `h` reports a merged, time-ordered, shell-tagged view across zsh/bash/fish
#                 via ~/.config/shell/hist-merge (read-only; no history files are modified)
#       shell:    `h` reports only zsh's own history
#   HISTORY_SCOPE / HISTORY_SCOPE_ZSH = local (default) | global
#       local:  use ./.zsh_history if it exists and cwd != HOME, else ~/.zsh_history
#       global: always ~/.zsh_history
#
# `h help` lists the h subcommands (swap/back to a directory's HISTFILE without writing to any
# history file, remove to delete entries, file for status; each has a single-letter alias);
# `hh` switches HISTFILE for real. Ctrl+R fzf-searches the same merged shell-tagged view
# (zsh-only in shell mode), read-only: picking an entry just puts it on the command line.
####################################################################################################

# Shared HISTFILE settings, applied at startup and by hh when switching HISTFILE
_hist_apply_settings() {
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
}

# If custom ~/.zsh_history in current folder respect it (unless scoped global)
if [[ "${HISTORY_SCOPE_ZSH:-${HISTORY_SCOPE:-local}}" == "local" && -f "$(pwd)/.zsh_history" && "$(pwd)" != "${HOME}" ]]; then
    HISTFILE="$(pwd)/.zsh_history"
else
    HISTFILE="$HOME/.zsh_history"
fi
_hist_apply_settings

# Files the merged view (and h rm) should look at: zsh's is the live HISTFILE so h swap/hh are
# reflected; bash/fish mirror hist-merge's own env-var resolution. Fills the _h_specs array.
_h_merge_specs() {
    local bscope="${HISTORY_SCOPE_BASH:-${HISTORY_SCOPE:-local}}"
    local bfile="${HOME}/.bash_history"
    [[ "${bscope}" == "local" && -f "${PWD}/.bash_history" && "${PWD}" != "${HOME}" ]] && bfile="${PWD}/.bash_history"
    _h_specs=("zsh:${HISTFILE:-${HOME}/.zsh_history}" "bash:${bfile}" "fish:${HOME}/.local/share/fish/fish_history")
}

# h file (and the tail of h help): the current history file of each shell, as the merged view
# resolves them, with swap status for this shell and a flag for files that don't exist yet
_h_files() {
    local -a _h_specs
    _h_merge_specs
    local spec sh path note
    for spec in "${_h_specs[@]}"; do
        sh="${spec%%:*}"
        path="${spec#*:}"
        note=""
        if [[ "${sh}" == "zsh" ]]; then
            note="this shell"
            (( ${_h_swap_depth:-0} > 0 )) && note+="; swapped read-only, depth ${_h_swap_depth}: 'h back' returns"
        fi
        [[ -f "${path}" ]] || note+="${note:+; }missing"
        printf '    %-5s %s%s\n' "${sh}:" "${path}" "${note:+ (${note})}"
    done
}

# h swap/back: read-only HISTFILE switch. fc -p pushes the current history list onto zsh's
# history stack and loads the target with SAVEHIST=0, so nothing is written to any history file
# while swapped (not even by SHARE_HISTORY); fc -P restores the previous list untouched.
_h_swap() {
    local target="${1:-${PWD}/.zsh_history}"
    if [[ ! -f "${target}" ]]; then
        echo "h swap: no history file at ${target} (hh creates a real local HISTFILE)"
        return 1
    fi
    fc -p "${target}" "${HISTSIZE}" 0
    _h_swap_depth=$(( ${_h_swap_depth:-0} + 1 ))
    echo "Swapped to ${target} (read-only: commands typed now are saved nowhere). 'h back' returns."
}

_h_back() {
    if (( ${_h_swap_depth:-0} == 0 )); then
        echo "h back: no swap active"
        return 1
    fi
    fc -P
    _h_swap_depth=$(( _h_swap_depth - 1 ))
    local extra=""
    (( _h_swap_depth > 0 )) && extra=" (still ${_h_swap_depth} swap(s) deep)"
    echo "Back on ${HISTFILE}${extra}"
}

# h remove: delete history entries, addressed by the numbers h displays. Edits the history files
# (agnostic mode can hit zsh/bash/fish files via hist-merge --lines; shell mode matches the fc
# entry's text in HISTFILE). Running shells may still hold deleted entries in memory.
_h_rm() {
    local mode="${HISTORY_MODE_ZSH:-${HISTORY_MODE:-agnostic}}"
    local merge="${HOME}/.config/shell/hist-merge"
    [[ -x "${merge}" ]] || mode="shell"
    if (( $# == 0 )); then
        echo "h remove: pass one or more entry numbers (as shown by h)"
        return 1
    fi
    local n
    for n in "$@"; do
        if [[ "${n}" != <-> ]]; then
            echo "h remove: '${n}' is not an entry number"
            return 1
        fi
    done
    local fish_hit=0 deleted=0
    if [[ "${mode}" == "agnostic" ]]; then
        local -a _h_specs
        _h_merge_specs
        local out
        out="$("${merge}" --lines "${(j:,:)@}" "${_h_specs[@]}")"
        local -A ranges found
        local num file s e c
        while IFS=$'\t' read -r num file s e c; do
            [[ -n "${num}" ]] || continue
            found[${num}]=1
            ranges[${file}]+="${s},${e}d;"
            [[ "${file}" == *fish_history ]] && fish_hit=1
            print -r -- "rm ${num}: [${file/#${HOME}/~}] ${c}"
        done <<< "${out}"
        for n in "$@"; do
            [[ -n "${found[${n}]:-}" ]] || echo "h remove: no entry ${n}"
        done
        (( ${#ranges} )) || return 1
        for file in "${(@k)ranges}"; do
            sed -i "${ranges[${file}]%;}" "${file}"
        done
        deleted=1
    else
        local text range
        for n in "$@"; do
            text="$(fc -ln "${n}" "${n}" 2>/dev/null)"
            if [[ -z "${text}" ]]; then
                echo "h remove: no entry ${n}"
                continue
            fi
            # Find the last entry in HISTFILE whose text matches, comparing in fc -ln form:
            # continuation lines of a multi-line entry joined with a literal backslash-n,
            # per-line whitespace trimmed. The range covers all continuation lines.
            range="$(TARGET="${text}" awk '
                function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
                function joined(c,   m, arr, j, o) {
                    m = split(c, arr, "\001"); o = ""
                    for (j = 1; j <= m; j++) o = o (j > 1 ? "\\n" : "") trim(arr[j])
                    return o
                }
                function check() { if (have && joined(cmd) == t) { ms = rstart; me = rend } have = 0 }
                BEGIN { t = trim(ENVIRON["TARGET"]) }
                {
                    line = $0
                    iscont = (line ~ /\\$/)
                    if (iscont) sub(/\\$/, "", line)
                    if (cont) {
                        cmd = cmd "\001" line; rend = NR
                    } else {
                        check()
                        sub(/^: [0-9]+:[0-9]+;/, "", line)
                        cmd = line; rstart = NR; rend = NR; have = 1
                    }
                    cont = iscont
                }
                END { check(); if (ms) print ms "," me }
            ' "${HISTFILE}")"
            if [[ -n "${range}" ]]; then
                print -r -- "rm ${n}: ${text}"
                sed -i "${range}d" "${HISTFILE}"
                deleted=1
            else
                echo "h remove: entry ${n} not found in ${HISTFILE}"
            fi
        done
    fi
    (( deleted )) && echo "(files updated; running shells may still hold deleted entries in memory)"
    (( fish_hit )) && echo "(fish rewrites its own file: fish entries can come back until fish restarts)"
    return 0
}

# fc aliases
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
    h s|swap [file]          switch to ./.zsh_history (or file), read-only: nothing is
                             written to any history file until you swap back
    h b|back                 undo the last swap (commands typed while swapped are discarded)
    h f|file                 list each shell's current history file (and swap status)
    h h|help | -h | --help   show this help message

Mode (HISTORY_MODE_ZSH, then HISTORY_MODE; default agnostic):
agnostic = read-only merged view across zsh/bash/fish via hist-merge; shell = zsh only

Notes:
    Delete several entries in one h remove call: the numbers shift after a deletion.
    h remove edits the files only; running shells may keep deleted entries in memory.
    h swap is the read-only counterpart of hh (which switches HISTFILE for real).
    The subcommand words and letters are reserved; to search one literally: h '(swap)'

Current history files:
EOF
            _h_files
    }
    local mode="${HISTORY_MODE_ZSH:-${HISTORY_MODE:-agnostic}}"
    local merge="${HOME}/.config/shell/hist-merge"
    [[ -x "${merge}" ]] || mode="shell"
    case "${1}" in
        h|help|-h|--help) usage; return 0 ;;
        r|rm|remove) shift; _h_rm "$@"; return $? ;;
        s|swap)      _h_swap "${2}"; return $? ;;
        b|back)      _h_back; return $? ;;
        f|file) _h_files; return 0 ;;
    esac
    local -a _h_specs
    _h_merge_specs
    if [[ -n "${1}" ]]; then
        if [[ "${1}" == <-> ]]; then
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
                fc -lf 1 | rg "${1}"
            fi
        fi
    else
        if [[ "${mode}" == "agnostic" ]]; then
            "${merge}" "${_h_specs[@]}"
        else
            fc -lf 1
        fi
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
    HISTFILE="$(pwd)/.zsh_history"
    if [[ ! -f "${HISTFILE}" && "$(pwd)" != "${HOME}" ]]; then
        cat "${OLD_HISTFILE}" > "${HISTFILE}"
    fi
    _hist_apply_settings
    echo "Switched HISTFILE to ${HISTFILE} from ${OLD_HISTFILE}"
}
alias hh='hh_func '

# Ctrl+R: fzf over the merged, shell-tagged history (agnostic mode; same files h uses, so
# swaps and local HISTFILEs are respected). Read-only: picking an entry only puts it on the
# command line. Shell mode falls back to zsh's incremental search.
_h_fzf_search() {
    local mode="${HISTORY_MODE_ZSH:-${HISTORY_MODE:-agnostic}}"
    local merge="${HOME}/.config/shell/hist-merge"
    [[ -x "${merge}" ]] || mode="shell"
    if [[ "${mode}" != "agnostic" ]]; then
        zle history-incremental-search-backward
        return
    fi
    local -a _h_specs
    _h_merge_specs
    local selection num
    selection="$("${merge}" "${_h_specs[@]}" | tac \
        | fzf --no-multi --scheme=history --query="${BUFFER}" \
              --header='merged zsh/bash/fish history (read-only)')"
    if [[ -n "${selection}" ]]; then
        num="${${(z)selection}[1]}"
        BUFFER="$("${merge}" --raw "${num}" "${_h_specs[@]}")"
        CURSOR=${#BUFFER}
    fi
    zle reset-prompt
}
if (( $+commands[fzf] )); then
    zle -N _h_fzf_search
    bindkey '^R' _h_fzf_search
fi

# History search bindings
autoload -U up-line-or-beginning-search
autoload -U down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
# bindkey "^[[1;5A" up-line-or-beginning-search # Ctrl+Up
# bindkey "^[[1;5B" down-line-or-beginning-search # Ctrl+Down
