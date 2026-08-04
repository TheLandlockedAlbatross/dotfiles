####################################################################################################
# Package managers
# Consistent aliases regardless of distro:
#   install / remove / search / update — map to the native package manager
#   installed                         — explicitly-installed (non-dependency) packages
#   installed_neat                    — two-column binaries/libraries view of the above
####################################################################################################

if command -v apt &> /dev/null; then
    _pkg_manual_list() { apt-mark showmanual }
    alias install='sudo apt install -y'
    alias remove='sudo apt-get remove '
    alias search='apt search --names-only'
    alias update='sudo apt-get update && sudo apt-get upgrade'
elif command -v dnf &> /dev/null; then
    _pkg_manual_list() { dnf repoquery --userinstalled --qf '%{name}\n' 2> /dev/null }
    alias install='sudo dnf install -y'
    alias remove='sudo dnf remove '
    alias search='dnf search '
    alias update='sudo dnf upgrade'
elif command -v yay &> /dev/null; then
    # AUR helper (Arch/omarchy) — self-elevates, must NOT be run with sudo
    _pkg_manual_list() { yay -Qqe }
    alias install='yay -S --noconfirm '
    alias remove='yay -R '
    alias search='yay -Ss '
    alias update='yay -Syu'
elif command -v pacman &> /dev/null; then
    _pkg_manual_list() { pacman -Qqe }
    alias install='sudo pacman -S --noconfirm '
    alias remove='sudo pacman -R '
    alias search='pacman -Ss '
    alias update='sudo pacman -Syu'
elif command -v zypper &> /dev/null; then
    _pkg_manual_list() { zypper --quiet search -i -t package | awk -F'|' 'NR > 2 { gsub(/ /, "", $2); print $2 }' }
    alias install='sudo zypper install -y '
    alias remove='sudo zypper remove '
    alias search='zypper search '
    alias update='sudo zypper refresh && sudo zypper update'
elif command -v apk &> /dev/null; then
    _pkg_manual_list() { cat /etc/apk/world 2> /dev/null }
    alias install='sudo apk add '
    alias remove='sudo apk del '
    alias search='apk search '
    alias update='sudo apk update && sudo apk upgrade'
fi

# Only defined when a supported package manager was found above
if (( ${+functions[_pkg_manual_list]} )); then
    alias installed='_pkg_manual_list'
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
        done < <(_pkg_manual_list | sort)

        local max=$(( ${#bins[@]} > ${#libs[@]} ? ${#bins[@]} : ${#libs[@]} ))
        local available=$(( ${LINES:-40} - 5 ))
        local display_max=$max truncated=false

        if [[ $show_all == false && $max -gt $available ]]; then
            display_max=$available
            truncated=true
        fi

        printf '\e[1;32m%-42s\e[0m \e[1;36m%s\e[0m\n' '📦 BINARIES' '📚 LIBRARIES'
        printf '\e[32m%-42s\e[0m \e[36m%s\e[0m\n' '──────────────────────────────────────' '──────────────────────────────────────'
        for (( i = 1; i <= display_max; i++ )); do
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
fi
