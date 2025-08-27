if command -v flatpak > /dev/null; then
    # Add to PATH w/o conflicting with local installs

    rm -f /usr/local/bin/flatpak/*
    # List installed applications with their version and branch
    flatpak list --app --columns=application,version,branch | while read -r app version branch; do
        # Define the path to the .desktop file
        desktop_file="/var/lib/flatpak/exports/share/applications/${app}.desktop"

        # Check if the .desktop file exists
        if [ -f "${desktop_file}" ]; then
            # Extract the Exec line from the .desktop file
            exec_command=$(awk -F'Exec=' '/^Exec=/{print $2}' "${desktop_file}" | cut -d'@' -f1)
            exec_path=/usr/local/bin
            if [ -n "${exec_command}" ]; then
                link_name=$(echo "${app}" | awk -F"." '{print $NF}' | tr '[:upper:]' '[:lower:]')
                if command -v "${link_name}" > /dev/null; then
                    if command -v "${link_name}-${version}" > /dev/null; then
                        echo "${exec_command} \"\$@\"" | tee "${exec_path}"/"${link_name}-${version}-${branch}"
                        chmod 755 "${exec_path}"/"${link_name}"
                    else
                        echo "${exec_command} \"\$@\"" | tee "${exec_path}"/"${link_name}-${version}"
                        chmod 755 "${exec_path}"/"${link_name}"
                    fi
                else
                    echo "${exec_command} \"\$@\"" | tee "${exec_path}"/"${link_name}"
                    chmod 755 "${exec_path}"/"${link_name}"
                fi
            fi
        fi
    done
    # chmod 755 /usr/local/bin/flatpak/*
    # PATH="/usr/local/bin/flatpak:$PATH"
    # export PATH
fi
