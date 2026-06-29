# Easy way to change prompt length if bothersome for terminal window size
r-- () {
    export PROMPT_DIRTRIM=1
    # Reset if any args given
    [[ -n $@ ]] && reset
}
r++ () {
    export PROMPT_DIRTRIM=0
    # Reset if any args given
    [[ -n $@ ]] && reset
}
r- () {
    cwd=$(pwd)
    cwd_no_slashes=${cwd//"/"}
    cwd_num_slashes=$(( ${#cwd} - ${#cwd_no_slashes} ))
    if [[ ${PROMPT_DIRTRIM} -gt 1 ]]; then
        export PROMPT_DIRTRIM=$(( ${PROMPT_DIRTRIM} - 1 )) 
        # Reset if any args given
        [[ -n $@ ]] && reset
    elif [[ ${PROMPT_DIRTRIM} -eq 0 ]]; then
        export PROMPT_DIRTRIM=$(( ${cwd_num_slashes} - 1 )) 
        # Reset if any args given
        [[ -n $@ ]] && reset
    fi
}
r+ () {
    cwd=$(pwd)
    cwd_no_slashes=${cwd//"/"}
    cwd_num_slashes=$(( ${#cwd} - ${#cwd_no_slashes} ))
    if [[ ${PROMPT_DIRTRIM} -lt ${cwd_num_slashes} && ${PROMPT_DIRTRIM} -gt 0 ]]; then
        export PROMPT_DIRTRIM=$(( ${PROMPT_DIRTRIM} + 1 ))
        # Reset if any args given
        [[ -n $@ ]] && reset
    fi
}
