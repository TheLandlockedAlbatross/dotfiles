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
# `h help` lists the h subcommands (swap/back: read-only switch to the history files found in a
# directory, remove to delete entries, file for status; each has a single-letter alias);
# `hh` creates local history files for every installed shell and switches HISTFILE for real.
# Ctrl+R fzf-searches the same merged shell-tagged view (zsh-only in shell mode), read-only:
# picking an entry just puts it on the command line.
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

# Where a shell's history file lives right now, ignoring swaps and pins: ./.<shell>_history if
# scope is local, it exists and cwd != HOME, else the shell's global file (hist-merge's own rule)
_h_shells=(zsh bash fish)
_h_resolve() {
    local sh="${1}" scope_var="HISTORY_SCOPE_${(U)1}" global="${HOME}/.${1}_history"
    [[ "${sh}" == "fish" ]] && global="${HOME}/.local/share/fish/fish_history"
    if [[ "${(P)scope_var:-${HISTORY_SCOPE:-local}}" == "local" && -f "${PWD}/.${sh}_history" && "${PWD}" != "${HOME}" ]]; then
        echo "${PWD}/.${sh}_history"
    else
        echo "${global}"
    fi
}

# If custom .zsh_history in current folder respect it (unless scoped global)
HISTFILE="$(_h_resolve zsh)"
_hist_apply_settings

# Files the merged view (and h rm, h file, Ctrl+R) look at, per shell; first match wins:
#   1. _h_swap_over  temporary override pushed by h swap, popped by h back
#   2. _h_pin        persistent override set by hh for the other shells' new local files
#   3. this shell's live HISTFILE (h swap's fc -p and hh both move it)
#   4. _h_resolve    cwd/scope resolution
# Fills the _h_specs array. _h_swap_stack holds one record per active swap: first line 1 if the
# swap pushed this shell's own history (fc -p), the rest a snapshot of _h_swap_over before it;
# _h_swap_pushed counts the records that did.
typeset -gA _h_swap_over _h_pin
typeset -ga _h_swap_stack
_h_merge_specs() {
    local sh path
    _h_specs=()
    for sh in "${_h_shells[@]}"; do
        if [[ -n "${_h_swap_over[${sh}]:-}" ]]; then
            path="${_h_swap_over[${sh}]}"
        elif [[ -n "${_h_pin[${sh}]:-}" ]]; then
            path="${_h_pin[${sh}]}"
        elif [[ "${sh}" == "zsh" ]]; then
            path="${HISTFILE:-${HOME}/.zsh_history}"
        else
            path="$(_h_resolve "${sh}")"
        fi
        _h_specs+=("${sh}:${path}")
    done
}

# h file (and the tail of h help): the current history file of each shell, as the merged view
# resolves them, with swap/pin status and a flag for files that don't exist yet
_h_files() {
    local -a _h_specs
    _h_merge_specs
    local spec sh path note
    for spec in "${_h_specs[@]}"; do
        sh="${spec%%:*}"
        path="${spec#*:}"
        note=""
        [[ "${sh}" == "zsh" ]] && note="this shell"
        if [[ -n "${_h_swap_over[${sh}]:-}" || ( "${sh}" == "zsh" && ${_h_swap_pushed:-0} -gt 0 ) ]]; then
            note+="${note:+; }swapped read-only: 'h back' returns"
        elif [[ -n "${_h_pin[${sh}]:-}" ]]; then
            note+="${note:+; }pinned by hh"
        fi
        [[ -f "${path}" ]] || note+="${note:+; }missing"
        printf '    %-5s %s%s\n' "${sh}:" "${path}" "${note:+ (${note})}"
    done
    (( ${#_h_swap_stack} > 0 )) && echo "    (${#_h_swap_stack} swap(s) active)"
    return 0
}

# h swap/back: read-only switch of the history files h looks at. Arguments: none (every history
# file in cwd), directories (every history file there), files (shell inferred from the name) or
# explicit shell:path specs. This shell's own file is loaded with fc -p, which pushes the current
# history list onto zsh's history stack and loads the target with SAVEHIST=0, so nothing is
# written to any history file while swapped (not even by SHARE_HISTORY); fc -P restores the
# previous list untouched. The other shells' files only change the merged view. Ignores
# HISTORY_SCOPE: an explicit swap wins.
_h_swap_targets() {   # fills the caller's _h_want assoc (shell -> absolute path) from swap args
    local arg sh path dir
    for arg in "${@:-${PWD}}"; do
        if [[ -d "${arg}" ]]; then
            dir="${arg:a}"
            for sh in "${_h_shells[@]}"; do
                [[ -f "${dir}/.${sh}_history" ]] && _h_want[${sh}]="${dir}/.${sh}_history"
            done
            continue
        fi
        if [[ "${arg}" == (zsh|bash|fish):* ]]; then
            sh="${arg%%:*}"
            path="${arg#*:}"
        else
            path="${arg}"
            case "${path:t}" in
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
        _h_want[${sh}]="${path:a}"
    done
    if (( ${#_h_want} == 0 )); then
        echo "h swap: no .zsh_history/.bash_history/.fish_history in ${*:-${PWD}}"
        return 1
    fi
    return 0
}

_h_swap() {
    local -A _h_want
    _h_swap_targets "$@" || return 1
    local record="0" sh
    for sh in "${(@k)_h_swap_over}"; do
        record+=$'\n'"${sh}"$'\t'"${_h_swap_over[${sh}]}"
    done
    for sh in "${_h_shells[@]}"; do
        [[ -n "${_h_want[${sh}]:-}" ]] || continue
        if [[ "${sh}" == "zsh" ]]; then
            fc -p "${_h_want[zsh]}" "${HISTSIZE}" 0
            record="1${record#0}"
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
    if (( ${#_h_swap_stack} == 0 )); then
        echo "h back: no swap active"
        return 1
    fi
    local record="${_h_swap_stack[-1]}"
    _h_swap_stack[-1]=()
    local -a lines
    lines=("${(@f)record}")
    if [[ "${lines[1]}" == "1" ]]; then
        fc -P
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
    h s|swap [target ...]    switch to every history file found in cwd (or in the given
                             directories / the given files), read-only: nothing is written
                             to any history file until you swap back
    h b|back                 undo the last swap (commands typed while swapped are discarded)
    h f|file                 list each shell's current history file (and swap/pin status)
    h h|help | -h | --help   show this help message

Mode (HISTORY_MODE_ZSH, then HISTORY_MODE; default agnostic):
agnostic = read-only merged view across zsh/bash/fish via hist-merge; shell = zsh only

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
    local mode="${HISTORY_MODE_ZSH:-${HISTORY_MODE:-agnostic}}"
    local merge="${HOME}/.config/shell/hist-merge"
    [[ -x "${merge}" ]] || mode="shell"
    case "${1}" in
        h|help|-h|--help) usage; return 0 ;;
        r|rm|remove) shift; _h_rm "$@"; return $? ;;
        s|swap)      shift; _h_swap "$@"; return $? ;;
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

# hh: start local history files for every installed shell in cwd, each seeded with that shell's
# current history, and switch this shell's HISTFILE to its one for real. The other shells' files
# are pinned for the merged view and picked up by those shells when they start in this directory
# (HISTORY_SCOPE local). In $HOME: switch back to the global files and drop the pins instead.
hh_func() {
    usage() {
        cat <<EOF
Create ./.<shell>_history for every installed shell (zsh/bash/fish), seeded with that shell's
current history, and switch this shell's HISTFILE to ./.zsh_history for real. Run in \$HOME to
switch back to the global files. h swap is the read-only counterpart.
Usage: hh [-y|-h]

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

    if (( ${#_h_swap_stack} > 0 )); then
        echo "hh: a swap is active; run 'h back' first"
        return 1
    fi

    local -a shells
    local sh
    for sh in "${_h_shells[@]}"; do
        (( $+commands[${sh}] )) && shells+=("${sh}")
    done

    local question
    if [[ "${PWD}" == "${HOME}" ]]; then
        question="Switch back to the global history files and drop hh pins?"
    else
        question="Create local history files in ${PWD} for ${shells[*]} and switch this shell's HISTFILE to ./.zsh_history?"
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
        HISTFILE="${HOME}/.zsh_history"
        _hist_apply_settings
        _h_pin=()
        echo "Back on the global history files:"
        _h_files
        return 0
    fi

    local src dst
    for sh in "${shells[@]}"; do
        dst="${PWD}/.${sh}_history"
        if [[ "${sh}" == "zsh" ]]; then
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
        if [[ "${sh}" == "zsh" ]]; then
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
