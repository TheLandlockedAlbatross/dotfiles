#!/bin/bash

# Variables
PANEL_ID=2  # Specify the panel number (0-based index for xfconf)
LAUNCHER_ID=16  # Unique ID for the new launcher
LAUNCHER_NAME="MyApp"  # Name of your application
DESKTOP_FILE="/usr/share/applications/myapp.desktop"  # Path to your .desktop file
LAUNCHER_DIR="$HOME/.config/xfce4/panel/launcher-$LAUNCHER_ID"

PANEL_DIR="$HOME/.config/xfce4/panel/"
NUM_PANELS="$(xfconf-query -c xfce4-panel -p /panels | grep -c '^[0-9]\+')"
if [ -d "${PANEL_DIR}" ]; then
    pushd "${PANEL_DIR}"

    for panel in $(seq 1 ${NUM_PANELS}); do
        plugin_ids=$(xfconf-query -c xfce4-panel -p /panels/panel-${panel}/plugin-ids | \grep '^[0-9]\+')
        plugin_ids_to_keep=()
        update=""
        for id in $plugin_ids; do
            res="$(xfconf-query -c xfce4-panel -p /plugins/plugin-${id})"
            if [ "${res}" == "i3-workspaces" ]; then
                # Reset plugin-ids later
                # Remove old i3 plugin
                xfconf-query -c xfce4-panel -p /plugins/plugin-${id} --reset --recursive
                # Create new i3 plugin
                xfconf-query -c xfce4-panel -p /plugins/plugin-${id} -n -t string -s "i3-workspaces"
                xfconf-query -c xfce4-panel -p /plugins/plugin-${id}/use_css -t bool -s true --create
                xfconf-query -c xfce4-panel -p /plugins/plugin-${id}/normal_color -t string -s "rgb(0,0,0)" --create
                xfconf-query -c xfce4-panel -p /plugins/plugin-${id}/focused_color -t string -s "rgb(0,0,0)" --create
                xfconf-query -c xfce4-panel -p /plugins/plugin-${id}/urgent_color -t string -s "rgb(255,0,0)" --create
                xfconf-query -c xfce4-panel -p /plugins/plugin-${id}/mode_color -t string -s "rgb(255,0,0)" --create
                xfconf-query -c xfce4-panel -p /plugins/plugin-${id}/visible_color -t string -s "rgb(0,0,0)" --create
                xfconf-query -c xfce4-panel -p /plugins/plugin-${id}/css -t string -s \
                    '.workspace { \n\tcolor: #FFFFFF;\n\tfont-family: "Symbols Nerd Font", sans-serif;\n\tfont-size: 16px;\n\tmargin-left: 2px;\n\tmargin-right: 2px;\n}\n.workspace.visible { \n\tcolor: #69A31F;\n\tfont-size: 20px;\n}\n.workspace.focused { \n\tfont-weight: bold; \n}\n.workspace.urgent { color: red; }\n.binding-mode { }' --create
                xfconf-query -c xfce4-panel -p /plugins/plugin-${id}/strip_workspace_numbers -t bool -s false --create
                xfconf-query -c xfce4-panel -p /plugins/plugin-${id}/auto_detect_outputs -t bool -s true --create
                xfconf-query -c xfce4-panel -p /plugins/plugin-${id}/output -t string -s "" --create
                xfce4-panel -r
            else
                plugin_ids_to_keep+=($id)
            fi
        done
        if [ -n "${update}" ]; then
            echo xfconf-query -c xfce4-panel -p /panels/panel-${panel}/plugin-ids --reset
            reset_cmd_fragment=""
            for plugin_id_to_keep in "${plugin_ids_to_keep[@]}"; do
                reset_cmd_fragment+=" --force-array --type int --set ${plugin_id_to_keep}"
            done
            if [ -n "${reset_cmd_fragment}" ]; then
                xfconf-query -c xfce4-panel -p /panels/panel-2/plugin-ids${reset_cmd_fragment}
            fi
        fi
    done

    popd
fi

