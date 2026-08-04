# Easy way to change prompt length if bothersome for terminal window size.
# p10k analog of bash's PROMPT_DIRTRIM: POWERLEVEL9K_SHORTEN_DIR_LENGTH is the
# number of trailing directory segments shown in full (the rest shorten per
# POWERLEVEL9K_SHORTEN_STRATEGY). p10k caches config, so reload after changing.
_prompt_dirtrim() {
    typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=$1
    [[ -n "$2" ]] && typeset -g POWERLEVEL9K_DIR_MAX_LENGTH=$2
    (( ${+functions[p10k]} )) && p10k reload
}
# maximum shortening: only the last dir in full (the p10k config default)
r-- () { _prompt_dirtrim 1 80 }
# no shortening: full path
r++ () { _prompt_dirtrim 99 4096 }
# one fewer full segment
r- () {
    local n=${POWERLEVEL9K_SHORTEN_DIR_LENGTH:-1}
    (( n > 1 )) && _prompt_dirtrim $(( n - 1 ))
}
# one more full segment
r+ () { _prompt_dirtrim $(( ${POWERLEVEL9K_SHORTEN_DIR_LENGTH:-1} + 1 )) }
