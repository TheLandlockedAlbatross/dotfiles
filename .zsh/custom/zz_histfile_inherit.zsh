####################################################################################################
# Inherit the parent pane's HISTFILE into new tmux panes/windows.
#
# `h swap` and `hh` both move this shell's live HISTFILE (fc -p / assignment).
# A freshly split pane runs a new shell that would otherwise re-resolve HISTFILE
# from cwd/scope (history.zsh) and ignore the swap. So: each prompt publishes
# this shell's current HISTFILE to the tmux session environment (and a per-pane
# option, which the pane-focus-in hook in tmux.conf uses to keep the session env
# pointed at the pane you are actually on); a new pane inherits TLA_HISTFILE in
# its environment and adopts it here, AFTER history.zsh has run (zz_ sorts last).
####################################################################################################

if [[ -n "$TMUX" ]]; then
    # Adopt the HISTFILE handed down from the pane we were split from.
    if [[ -n "${TLA_HISTFILE:-}" && -f "${TLA_HISTFILE}" && "${TLA_HISTFILE}" != "${HISTFILE}" ]]; then
        HISTFILE="${TLA_HISTFILE}"
        fc -R "${HISTFILE}" 2>/dev/null   # load the inherited history now
    fi

    # Publish the live HISTFILE to tmux before each prompt, but only when it
    # actually changed (avoids a tmux fork on every prompt). Sets both the
    # session env (inherited by new panes) and a per-pane option (read by the
    # pane-focus-in hook so focusing a pane makes it the inheritance source).
    _tla_publish_histfile() {
        [[ -n "$TMUX" ]] || return
        [[ "$HISTFILE" == "${_tla_last_pub_histfile:-}" ]] && return
        tmux set-environment TLA_HISTFILE "$HISTFILE" 2>/dev/null
        tmux set -p @tla_histfile "$HISTFILE" 2>/dev/null
        _tla_last_pub_histfile="$HISTFILE"
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _tla_publish_histfile
    _tla_publish_histfile
fi
