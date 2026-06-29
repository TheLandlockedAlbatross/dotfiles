# apt
if command -v apt &> /dev/null; then
    alias install='sudo apt install -y'
    alias installed='apt-mark showmanual'
    installed_neat_func() {
        local show_all=false
        while [[ $# -gt 0 ]]; do
            case $1 in
                -a|--all) show_all=true; shift ;;
                -h|--help)
                    printf 'Usage: installed_neat [-a|--all] [-h|--help]\n'
                    printf '  -a, --all   Show all packages without truncation\n'
                    printf '  -h, --help  Show this help message\n'
                    return 0
                    ;;
                *) shift ;;
            esac
        done

        local libs=() bins=()
        while read -r pkg; do
            [[ $pkg == lib* ]] && libs+=("$pkg") || bins+=("$pkg")
        done < <(apt-mark showmanual | sort)

        local max=$(( ${#bins[@]} > ${#libs[@]} ? ${#bins[@]} : ${#libs[@]} ))
        local available=$(( LINES - 5 ))
        local display_max=$max truncated=false

        if [[ $show_all == false && $max -gt $available ]]; then
            display_max=$available
            truncated=true
        fi

        printf '\e[1;32m%-42s\e[0m \e[1;36m%s\e[0m\n' '📦 BINARIES' '📚 LIBRARIES'
        printf '\e[32m%-42s\e[0m \e[36m%s\e[0m\n' '──────────────────────────────────────' '──────────────────────────────────────'
        for (( i=0; i<display_max; i++ )); do
            local bin_col="" lib_col=""
            [[ -n ${bins[i]:-} ]] && bin_col="  ${bins[i]}"
            [[ -n ${libs[i]:-} ]] && lib_col="  ${libs[i]}"
            printf '\e[32m%-42s\e[0m \e[36m%s\e[0m\n' "$bin_col" "$lib_col"
        done

        if [[ $truncated == true ]]; then
            printf '\e[33m... %d more rows. Use -a/--all to show all, -h/--help for help.\e[0m\n' "$(( max - display_max ))"
        fi
    }
    alias installed_neat='installed_neat_func '
    alias remove='sudo apt-get remove '
    alias search='apt search --names-only'
    alias update='sudo apt-get update && sudo apt-get upgrade'
fi
