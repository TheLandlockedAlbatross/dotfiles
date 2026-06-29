qbt_inspect  () {
    if curl --head --silent --fail "${1}" &> /dev/null; then
        local temp="a.torrent" 
        curl -s -o "${temp}" "${1}"
        transmission-show "${temp}" && rm "${temp}"
    else
        echo "Url \"${1}\" is invalid"
    fi
}

qbit_yts_mx_download () {
    # Error/warning strings for logging
    local error_str="ERROR: $0"
    local warning_str="WARNING: $0"
    local exit_flag=0
    local src=""
    local dest=""
    local output_name=""

    # parse args
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -h) 
                echo "qbit_yts_download [YTS.MX URL] [PATH] [NAME?]"
                echo "    If no name provided, use the Name: portion of torrent metadata to find <Media Name> <Year>"
                shift ;;
            *)
                if curl --head --silent --fail "${1}" &> /dev/null; then
                    if [[ -z "${src}" ]]; then
                        if [[ "${1}" =~ ^http(s?)://yts.mx/.*$ ]]; then
                            local src="${1}"
                        else
                            echo "${error_str} URL must be from https://yts.mx"
                            local exit_flag=1
                        fi
                    else
                        echo "${error_str} More than one URL specified"
                        local exit_flag=1
                    fi
                elif [[ -d "${dest}" ]]; then
                    if [[ -z "${dest}" ]]; then 
                        local dest="${1}"
                    else
                        echo "${error_str} More than one destination file specified"
                        local exit_flag=1
                    fi
                elif [[ -z "${output_name}" ]]; then
                    local output_name="${1}"
                fi
                shift;;
        esac
    done
    if [[ ${exit_flag} == "0" ]]; then
        # Use torrent data to get default name if not provided
        local torrent_name="$(qbt_inspect ${src} | rg -o --pcre2 '(?<=Name: )[^$]*' -m 1).torrent"
        if [[ -z "${output_name}" ]]; then
            local output_name=$(qbt_inspect "${src}" | rg -o --pcre2 '(?<=Name: )[^[]*' -m 1)
        fi
        echo "${torrent_name}"
        echo "${output_name}"
        mkdir -p "${dest}/${output_name}/"
        pushd "${dest}/${output_name}"
        curl -o "${torrent_name}" "${src}"
        popd
        qbittorrent "${dest}/${output_name}/${torrent_name}" --save-path="${dest}/${output_name}/" --add-paused=false
    fi
}
