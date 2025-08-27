random_userstring() {
    p_length=$1
    p_complexity=$2

    if [[ -z "${p_length}" ]]; then
        p_length=16
    fi
    if [[ -z "${p_complexity}" ]]; then
        p_complexity=3
    fi

    if [[ ${p_complexity} == 1 ]]; then
        charSet="A-Za-z"
    elif [[ ${p_complexity} == 2 ]]; then
        charSet="A-Za-z0-9"
    elif [[ ${p_complexity} == 3 ]]; then
        charSet="A-Za-z0-9!\"#\$%&'()*+,-./:;<=>?@[\]^_\`{|}~"
    else
        charSet="A-Za-z0-9!\"#\$%&'()*+,-./:;<=>?@[\]^_\`{|}~"
    fi
    tr -dc "${charSet}" </dev/urandom | head -c "${p_length}"; echo
}
