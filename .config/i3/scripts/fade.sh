#!/bin/bash

if [ -z "$1" ]; then
    echo "Need window name (and optional opacity and fade duration)"
    exit 1
fi

# Process args
WINDOWID=""
OPACITY=""
FADE_DURATION=""

args="k"
KILL_FLAG=""
while [[ $# -gt 0 ]]; do
    case "${1}" in
        -k | --kill)
            KILL_FLAG=1
            shift;;
        *)
            if [[ -z ${WINDOWID} && "${1}" =~ ^[0-9]+$ ]]; then
                WINDOWID="${1}"
            elif [[ -z ${OPACITY} && "${1}" =~ ^[0-9]+$ ]]; then
                OPACITY="${1}"
            elif [[ -z ${FADE_DURATION} && "${1}" =~ ^[0-9.]+$ ]]; then
                echo test
                FADE_DURATION=$(echo "${1}" | bc -l)
            fi
            shift ;;
    esac
done

if [[ -z ${OPACITY} ]]; then
    OPACITY="50"
fi

if [[ -z ${FADE_DURATION} ]]; then
    FADE_DURATION="1"
fi

# Function to fade to the target opacity
fade_to_opacity() {
    # base values
    local start_opacity=$1
    local end_opacity=$2
    local difference=$((end_opacity-start_opacity))

    # From experimentation going 0 to 100, 20 is smallest amount of steps that appear smooth to human eye
    local MINIMUM_STEPS=100
    local MINIMUM_FADE_DURATION=$(echo "0.104" | bc -l)

    local steps="${MINIMUM_STEPS}"
    local step_duration=$(echo "${FADE_DURATION} / (1 / ${FADE_DURATION} * ${steps} + ${steps})"  | bc -l)

    #local steps=33
    #local adjust=3.66
    #local step_duration=$(echo "$FADE_DURATION / ($adjust * $steps)" | bc -l)
    #local step_duration=$(printf "$FADE_DURATION")
    echo "FADE: $FADE_DURATION"
    echo "STEP: $step_duration"


    for ((i=1; i<=steps; i++)); do
        local opacity_step=$(( start + (i * difference / steps) ))
        local opacities+=("$(printf '0x%x' ${opacity_step})")
    done

    # This block is ~7ms off supplied step time
    # Sleep is generally 3 ms off, xprop generally takes 4 ms
    # With no sleep, takes ~0.1s
    for opacity in "${opacities[@]}"; do
        xprop -id "$WINDOWID" -f _NET_WM_WINDOW_OPACITY 32c -set _NET_WM_WINDOW_OPACITY "${opacity}"
        if [ $(echo "${FADE_DURATION} > ${MINIMUM_FADE_DURATION}" | bc) -eq 1 ]; then
            sleep "${step_duration}"
        fi
    done
}

# Calculate target opacity in hex format
target_opacity_hex=$(printf 0x%x $((0xffffffff * OPACITY / 100)))

# Set current opacity
current_opacity=$(xprop -id "$WINDOWID" _NET_WM_WINDOW_OPACITY | awk '{print $3}')

if [[ "$current_opacity" =~ ^[0-9]+$ ]]; then
    # If cardinal convert to hex
    current_opacity=$(printf '0x%x' $current_opacity)
else
    # If not set for window, assume it is at full opacity
    current_opacity=0xffffffff
fi

fade_to_opacity "$current_opacity" "$target_opacity_hex"
if [[ -n "${KILL_FLAG}" ]]; then
    i3-msg "[id=${WINDOWID}] kill"
fi


