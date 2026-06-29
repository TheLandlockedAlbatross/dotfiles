# $1 - path to nitrogen cfg folder of form:
#   .config/nitrogen/
#   ├── bg-saved.cfg
#   └── nitrogen.cfg
# If path given, script copies new cfg files and moves old ones to *-old:
#   .config/nitrogen/
#   ├── bg-saved.cfg -> bg-saved-old-$(date +%s).cfg
#   ├── nitrogen.cfg -> nitrogen-old-$(date +%s).cfg
#   ├── bg-saved.cfg <- $1/bg-saved.cfg
#   └── nitrogen.cfg <- $1/nitrogen.cfg
# If no path given AND *-old-... pair present, delete current cfg files and restore newest *-old-... pair:
#   .config/nitrogen/
#   ├── bg-saved.cfg -> <DELETE>
#   ├── nitrogen.cfg -> <DELETE>
#   ├── bg-saved-old-<MOST RECENT>.cfg -> bg-saved.cfg
#   ├── nitrogen-<MOST RECENT>$(date +%s).cfg -> nitrogen.cfg
#   ├── bg-saved-old-<OTHER>.cfg -> <NOTHING>
#   ├── nitrogen-<OTHER>.cfg -> <NOTHING>
#   └── ...
swap_nitrogen_cfg() {
    nitrogen_cfg_dir="${HOME}/.config/nitrogen"
    if [[ -d "${nitrogen_cfg_dir}" ]]; then
        if [[ -d "${1}" ]]; then
            if [[ -f "${1}/bg-saved.cfg" && -f "${1}/nitrogen.cfg" ]]; then
                # Save original cfg files, but delete others
                original_nitrogen_cfg_file=$(find "${nitrogen_cfg_dir}" -type f -name "nitrogen-original-*" -printf "%T@ %p\n" | sort -n | cut -d ' ' -f 2 | head -n 1)
                original_bg_saved_cfg_file=$(find "${nitrogen_cfg_dir}" -type f -name "bg-saved-original-*" -printf "%T@ %p\n" | sort -n | cut -d ' ' -f 2 | head -n 1)
                if [[ -z "${original_nitrogen_cfg_file}" && -z "${original_bg_saved_cfg_file}" ]]; then
                    cp "${nitrogen_cfg_dir}/bg-saved.cfg" "${nitrogen_cfg_dir}/bg-saved-original-$(date +%s).cfg"
                    cp "${nitrogen_cfg_dir}/nitrogen.cfg" "${nitrogen_cfg_dir}/nitrogen-original-$(date +%s).cfg"
                else
                    # Delete current cfg files (safe b/c since they were swapped in they presumably exist somewhere else)
                    rm "${nitrogen_cfg_dir}/bg-saved.cfg" 
                    rm "${nitrogen_cfg_dir}/nitrogen.cfg" 
                fi
                # Copy new cfg files from $1
                cp "${1}/bg-saved.cfg" "${nitrogen_cfg_dir}/bg-saved.cfg"
                cp "${1}/nitrogen.cfg" "${nitrogen_cfg_dir}/nitrogen.cfg"
                nitrogen --restore
            else
                echo "ERROR ${FUNCNAME} -  \"${1}\" is missing one of two required nitrogen .cfg files (bg-saved.cfg and nitrogen.cfg)"
            fi
        else
            if [[ -z "${1}" ]]; then
                # Treat original files differently
                original_nitrogen_cfg_file=$(find "${nitrogen_cfg_dir}" -type f -name "nitrogen-original-*" -printf "%T@ %p\n" | sort -n | cut -d ' ' -f 2 | head -n 1)
                original_bg_saved_cfg_file=$(find "${nitrogen_cfg_dir}" -type f -name "bg-saved-original-*" -printf "%T@ %p\n" | sort -n | cut -d ' ' -f 2 | head -n 1)
                if [[ -f "${original_nitrogen_cfg_file}" && "${original_bg_saved_cfg_file}" ]]; then
                    # Delete current cfg files (safe b/c since they were swapped in they presumably exist somewhere else)
                    rm "${nitrogen_cfg_dir}/nitrogen.cfg"
                    rm "${nitrogen_cfg_dir}/bg-saved.cfg"
                    # Restore the most recent *-old-... files
                    mv "${original_nitrogen_cfg_file}" "${nitrogen_cfg_dir}/nitrogen.cfg"
                    mv "${original_bg_saved_cfg_file}" "${nitrogen_cfg_dir}/bg-saved.cfg"
                    nitrogen --restore
                else
                    echo "ERROR ${FUNCNAME} -  No old cfg files to restore:"
                    if [[ "$(command -v tree)" ]]; then
                        tree "${nitrogen_cfg_dir}"
                    else 
                        ls "${nitrogen_cfg_dir}"
                    fi
                fi
            else
                echo "ERROR ${FUNCNAME} -  No directory named \"${1}\""
            fi
        fi
    else
        echo "ERROR ${FUNCNAME} -  Nitrogen cfg dir missing from "${nitrogen_cfg_dir}", is it installed?"
    fi
}
alias nsw='swap_nitrogen_cfg '
