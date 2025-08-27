#!/bin/bash

# Error/warning strings for logging
error_str="ERROR: $0"
warning_str="WARNING: $0"

# Constants
TOTAL_DISPLAY_SIZE=$(xdpyinfo | grep dimensions | awk '{print $2}')
NUM_DISPLAYS=$(xrandr | \grep -c " connected")
DEFAULT_LOCK_IMG="$HOME/data/Pictures/Lock_Screens/4x(5120x2880)/cloudy_road.jpg"
DEFAULT_LOCK_ICONS="$HOME/data/Pictures/Lock_Icons/nothing.png"

# Args/Usage
usage () {
    echo "Usage: ./lock.sh [OPTION]... SRC"
    echo "Execute i3lock with image in SRC (if path to file) or a random image under SRC (if directory)"
    echo "Options:"
    echo -e "\t-h | --help)"
    echo -e "\t\tPrint usage and exit"
    echo -e "\t-r | --recurse)"
    echo -e "\t\tInclude subdirectories of path when picking random image"
    echo -e "\t-t | --tiled)"
    echo -e "\t\tTile image on lock screen."
}

args="chrt"
cache_flag=""
recurse_flag=""
tiled_flag=""
while [[ $# -gt 0 ]]; do
    case "${1}" in
        -c | --cache)
            cache_flag="1"
            shift;;
        -h | --help)
            usage
            exit 0
            shift;;
        -r | --recurse)
            recurse_flag="1"
            shift;;
        -t | --tiled)
            tiled_flag="1"
            shift;;
        *)
            if [[ -e "${1}" && -z "${src}" ]]; then
                src="${1}"
            elif [[ ! -z "${src}" ]]; then
                echo "${error_str} lock image path already set to \"${src}\""
                exit 1
            else
                echo "${error_str} Invalid/extraneous argument(s) \"${@}\""
                exit 1
            fi
            shift;;
    esac
done

if [ -z "${src}" ]; then
    src="${DEFAULT_LOCK_IMG}"
fi

# Helper functions
is_image() {
    identify "${1}" >/dev/null 2>&1 ; echo $?
}

is_display_size() {
    display_width=${TOTAL_DISPLAY_SIZE%%x*}
    display_height=${TOTAL_DISPLAY_SIZE#*x}
    img_width=$(identify -format "%w" "${1}")
    img_height=$(identify -format "%h" "${1}")

    if [[ "${display_width}" -le "${img_width}" && "${display_height}" -le "${img_height}" ]]; then
        echo "0"
    else
        echo "1"
    fi
}

# Has to be png
i3lock_img_format() {
    local img_path=$1
    local width=$2
    local height=$3

    if [ -f "$img_path" ]; then
        # Generate a random name for the new image in /tmp
        new_img_name="/tmp/$(date +%s)_$(basename "$img_path" | cut -d. -f1)_random.png"

        # Check if both width and height are provided for scaling
        if [ -n "$width" ] && [ -n "$height" ]; then
            convert "$img_path" -resize ${width}x${height} -gravity center -extent ${width}x${height} "$new_img_name"
        else
            convert "$img_path" "$new_img_name"
        fi

        echo "$new_img_name"
    else
        echo "Error: The specified image file does not exist."
    fi
}

my_i3lock () {
    BLANK='#00000000'
    CLEAR='#ffffff22'
    DEFAULT='#f09b2e'
    TEXT='#f09b2e'
    VERIFYING='#1dd400'
    WRONG='#f04020'
    KEY_FLASH='#ffffff'
    BACKSPACE_FLASH='#000000'

    REG_FONT="Fira Code"
    TIME_FONT="Fira Code"
    DATE_FONT="Fira Code"
    OUTLINE_COLOR='#000000'
    LARGE_FONT_SIZE=100
    LARGE_FONT_OUTLINE_SIZE=3
    MED_FONT_SIZE=50
    MED_FONT_OUTLINE_SIZE=2
    SMALL_FONT_SIZE=40
    SMALL_FONT_OUTLINE_SIZE=1.25

    LOCK_DISPLAY=1

    args_clock=(
        --clock
        --force-clock
        --time-color=$TEXT
        --time-font="${TIME_FONT}"
        --time-pos ix:iy-250
        --time-size=${LARGE_FONT_SIZE}
        --time-str="%H:%M:%S"
        --timeoutline-color="${OUTLINE_COLOR}"
        --timeoutline-width="${LARGE_FONT_OUTLINE_SIZE}"
    )
    args_date=(
        --date-color=$TEXT
        --date-font="${DATE_FONT}"
        --date-pos ix:iy-200
        --date-size=${SMALL_FONT_SIZE}
        --date-str="%A %d %B %Y"
        --dateoutline-color="${OUTLINE_COLOR}"
        --dateoutline-width="${SMALL_FONT_OUTLINE_SIZE}"
    )
    args_layout=(
        --{layout,greeter}-color=${DEFAULT}
        --{layout,verif,wrong,greeter}-font="${REG_FONT}"
        --{layout,verif,wrong,greeter}-size="${MED_FONT_SIZE}"
        --{layout,verif,wrong,greeter,modif}outline-color="${OUTLINE_COLOR}"
        --{layout,verif,wrong,greeter,modifier}outline-width="${MED_FONT_OUTLINE_SIZE}"
    )
    args_verifier=(
        --modif-color=${DEFAULT}
        --noinput-text="No Input"
        --verif-color=${VERIFYING}
        --verif-text="Verifying..."
        --wrong-color=${WRONG}
        --wrong-text="Wrong!"
    )
    args_bar=(
        # TODO: improve x/y coordinates being trial and error vs. proportional to display width / height
        # Cube style
        # --bar-base-width 64
        # --bar-count 4
        # --bar-direction=2
        # --bar-max-height 32
        # --bar-periodic-step 4
        # --bar-pos tx-32:ty+100
        # --bar-total-width 64
        # Between time / date
        --bar-pos tx-286:ty+12
        --bar-base-width 4
        --bar-total-width 568
        --bar-direction=2
        --bar-max-height 4
        --bar-count 32
        # Other settings
        --indicator
        --bar-indicator
        #--redraw-thread
        --bar-color=${DEFAULT}
        --ringver-color=${DEFAULT}
        --ringwrong-color=${DEFAULT}
        --separator-color=$DEFAULT
        --bshl-color=${WRONG}
        --keyhl-color=${KEY_FLASH}
    )
    args_ring=(
        --inside-color=$BLANK
        --line-color=$BLANK
        --radius 140
        --ringver-color=${VERIFYING}
        --ringwrong-color=$WRONG
        --separator-color=$DEFAULT
        --bshl-color=${BACKSPACE_FLASH}
        --keyhl-color=${KEY_FLASH}
    )
    args_misc=(
        #--no-verify
        --show-failed-attempts
        --screen=${LOCK_DISPLAY}
        --pointer=win # Don't hide mouse pointer in lock screen
        --color=00000000 # Show screen translucently while rendering lock image instead of a jarring color flash
    )


    # Ensure monitor settings are retained during/after lock
    . "${XDG_CONFIG_HOME:-${HOME}/.config/}/i3/scripts/monitors.sh"

    i3lock \
    "${args_clock[@]}" \
    "${args_date[@]}" \
    \
    "${args_layout[@]}" \
    "${args_verifier[@]}" \
    "${args_bar[@]}" \
    \
    "${args_misc[@]}" \
    $@

}

# Main
# Cache image to reuse if --cache selected, otherwise if given directory pick randomly
if [[ -n ${cache_flag} ]] ; then
    if [[ -d "${src}" ]]; then
        echo "${error_str} Must pass in either single file or nothing for --cache option"
        exit 1
    fi
    cache_target="${XDG_CACHE_HOME:-${HOME}/.cache/}/i3lock/$(basename ${src})"
    if [[ -f "${cache_target}" ]] ; then
        if [[ -n ${tiled_flag} ]]; then
            my_i3lock --image "${cache_target}" --tiling --nofork
        else
            my_i3lock --image "${cache_target}" --nofork
        fi
    else
        rm /tmp/i3_tmp_* &>/dev/null
        final_lock_img="i3_tmp_$(date '+%s')_$(basename ${src})"
        cp "${src}" "/tmp/${final_lock_img}"
        final_lock_img_path=/tmp/"${final_lock_img}"

        img_width=$(identify -format "%w" "${final_lock_img_path}")
        img_height=$(identify -format "%h" "${final_lock_img_path}")

        LOCK_ICON=$(find "${DEFAULT_LOCK_ICONS}" -maxdepth 1 -type l,f | tail -n +1 | shuf -n 1)
        if [[ -L "${LOCK_ICON}" ]]; then
            LOCK_ICON=$(readlink "${LOCK_ICON}")
        fi
        if [[ ${NUM_DISPLAYS} -eq 4 ]]; then
            convert "${final_lock_img_path}" "${LOCK_ICON}" -gravity center -composite "${final_lock_img_path}"
        elif [[ ${NUM_DISPLAYS} -eq 2 ]]; then
            convert "${final_lock_img_path}" "${LOCK_ICON}" -gravity South -composite "${final_lock_img_path}"
        elif [[ ${NUM_DISPLAYS} -eq 1 ]]; then
            convert "${final_lock_img_path}" \
            \( "${LOCK_ICON}" -resize 30% -flop \) -gravity northwest -geometry +450+150 -composite \
            \( "${LOCK_ICON}" -resize 30% \) -gravity northeast -geometry +450+150 -composite \
            "${final_lock_img_path}"
        fi

        convert "${final_lock_img_path}" -colorspace RGB "${final_lock_img_path}"

        mkdir -p "${XDG_CACHE_HOME}/i3lock"
        mv "${final_lock_img_path}" "${cache_target}"
        final_lock_img_path="${cache_target}"

        if [[ -n ${tiled_flag} ]]; then
            my_i3lock --image="${final_lock_img_path}" --nofork --tiling
        else
            my_i3lock --image "${cache_target}" --nofork
        fi
    fi
else
    # If path is a folder, pick a random image
    if [[ -d "${src}" ]]; then
        start_time=$(date +%s)
        max_time_seconds=20
        end_time=$((start_time + max_time_seconds))

        if [[ ! -n ${tiled_flag} ]]; then
            while [ $(date +%s) -lt $end_time ]; do
                if [[ -n "${recurse_flag}" ]]; then
                    random_file=$(find "${src}" -type f | shuf -n 1)
                else
                    random_file=$(find "${src}" -maxdepth 1 -type f | shuf -n 1)
                fi
                res=$(is_display_size "${random_file}")
                if [[ "${res}" -eq 0 ]]; then
                    rm /tmp/i3_tmp_* &>/dev/null
                    final_lock_img="i3_tmp_$(date '+%s')_$(basename ${random_file})"
                    cp "${random_file}" "/tmp/${final_lock_img}"
                    final_lock_img_path=/tmp/"${final_lock_img}"
                    break
                fi
            done

            if [[ -z "${final_lock_img_path}" ]]; then
                echo "${error_str} Couldn't find suitable image in ${max_time_seconds}s in ${src}"
                exit 1
            fi
        else
            while [ $(date +%s) -lt $end_time ]; do
                if [[ -n "${recurse_flag}" ]]; then
                    random_file=$(find "${src}" -type f | shuf -n 1)
                else
                    random_file=$(find "${src}" -maxdepth 1 -type f | shuf -n 1)
                fi
                res=$(is_display_size "${random_file}")
                if [[ "${res}" -eq 0 ]]; then
                    rm /tmp/i3_tmp_* &>/dev/null
                    final_lock_img="i3_tmp_$(date '+%s')_$(basename ${random_file})"
                    cp "${random_file}" "/tmp/${final_lock_img}"
                    final_lock_img_path=/tmp/"${final_lock_img}"
                    break
                fi
            done

            if [[ -z "${final_lock_img_path}" ]]; then
                echo "${error_str} Couldn't find suitable image in ${max_time_seconds}s in ${src}"
                exit 1
            fi
        fi
    else
        rm /tmp/i3_tmp_* &>/dev/null
        final_lock_img="i3_tmp_$(date '+%s')_$(basename ${src})"
        cp "${src}" "/tmp/${final_lock_img}"
        final_lock_img_path=/tmp/"${final_lock_img}"
    fi

    img_width=$(identify -format "%w" "${final_lock_img_path}")
    img_height=$(identify -format "%h" "${final_lock_img_path}")

    LOCK_ICON=$(find "${DEFAULT_LOCK_ICONS}" -maxdepth 1 -type l,f | tail -n +1 | shuf -n 1)
    if [[ -L "${LOCK_ICON}" ]]; then
        LOCK_ICON=$(readlink "${LOCK_ICON}")
    fi
    if [[ ${NUM_DISPLAYS} -eq 4 ]]; then
        convert "${final_lock_img_path}" "${LOCK_ICON}" -gravity center -composite "${final_lock_img_path}"
    elif [[ ${NUM_DISPLAYS} -eq 2 ]]; then
        convert "${final_lock_img_path}" "${LOCK_ICON}" -gravity South -composite "${final_lock_img_path}"
    elif [[ ${NUM_DISPLAYS} -eq 1 ]]; then
        convert "${final_lock_img_path}" \
        \( "${LOCK_ICON}" -resize 30% -flop \) -gravity northwest -geometry +450+150 -composite \
        \( "${LOCK_ICON}" -resize 30% \) -gravity northeast -geometry +450+150 -composite \
        "${final_lock_img_path}"
    fi

    if [[ ! -n ${tiled_flag} ]]; then
        convert "${final_lock_img_path}" RGB:- | my_i3lock --raw ${img_width}x${img_height}:rgb --image /dev/stdin  --nofork
    else
        my_i3lock --image="${final_lock_img_path}" --nofork --tiling
    fi
fi
