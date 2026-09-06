# Audio only, best quality, Opus (native stream preferred so opus->opus is a
# copy, not a re-encode). Optional start/end accept any yt-dlp time syntax
# (90, 1:30, 00:01:30.5); omit both for the whole track, omit end to run to
# the end of the video. Default filename is the sanitized video title, plus
# the time range when trimming (":" becomes "." for the filesystem); a fourth
# argument overrides the name entirely.
#   yt-dlp-OPUS <url> [start] [end] [name]
yt-dlp-OPUS() {
    local url="$1" start="$2" end="$3" name="$4"
    if [[ -z "$url" ]]; then
        echo "Usage: yt-dlp-OPUS <url> [start] [end] [name]"
        return 1
    fi
    local -a section cookies
    if [[ -n "$start" || -n "$end" ]]; then
        section=(--download-sections "*${start:-0}-${end:-inf}" --force-keyframes-at-cuts)
    fi
    # Age-gated videos: set YTDLP_COOKIE_PROFILE (e.g. "firefox:default-release")
    # in machine-local config (~/.zsh/local.zsh); unset = no cookies, portable.
    [[ -n "${YTDLP_COOKIE_PROFILE}" ]] && cookies=(--cookies-from-browser "${YTDLP_COOKIE_PROFILE}")
    if [[ -z "$name" ]]; then
        local title
        title=$(yt-dlp --get-title --no-playlist "${cookies[@]}" "$url" | head -n 1)
        # Same sanitizer as yt-dlp-FULL_ARCHIVE: alnum, space, _ and - survive
        name=$(echo "$title" | tr -cd '[:alnum:] _-' | tr ' ' '_')
        [[ -z "$name" ]] && name="audio"
        if [[ -n "$start" || -n "$end" ]]; then
            name+="_${${start:-0}//:/.}-${${end:-end}//:/.}"
        fi
    fi
    # Two stages: download the canonical best audio stream untouched (whatever
    # codec yt-dlp ranks highest), then make the .opus ourselves with ffmpeg —
    # stream-copied when the source is already Opus, else libopus 192k.
    yt-dlp -f bestaudio \
        --embed-metadata \
        "${section[@]}" "${cookies[@]}" \
        -o "${name}.dl.%(ext)s" \
        "$url" || return 1

    local -a dl_files=( "${name}".dl.*(N) )
    if (( ${#dl_files} == 0 )); then
        echo "yt-dlp-OPUS: download produced no file"
        return 1
    fi
    local src="${dl_files[1]}"
    local codec
    codec=$(ffprobe -v quiet -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$src")
    if [[ "$codec" == "opus" ]]; then
        ffmpeg -loglevel error -i "$src" -map_metadata 0 -c:a copy "${name}.opus"
    else
        ffmpeg -loglevel error -i "$src" -map_metadata 0 -c:a libopus -b:a 192k "${name}.opus"
    fi && rm -- "$src" && echo "→ ${name}.opus (source codec: ${codec})"
}

yt-dlp-FULL_ARCHIVE() {
    local url="$1"
    # Extract video title safely
    local title
    title=$(yt-dlp --get-title --no-playlist "$url" | head -n 1)
    # Sanitize title for filesystem
    local safe_title
    safe_title=$(echo "$title" | tr -cd '[:alnum:] _-' | tr ' ' '_')
    # Get current date and time
    local datetime
    datetime=$(date '+%Y-%m-%d_%H-%M-%S')
    # Create directory
    local dir="${safe_title}_archived_${datetime}"
    mkdir -p "$dir"
    pushd "${dir}"
    # Download into directory
    yt-dlp -f bestvideo+bestaudio \
        --embed-metadata \
        --embed-thumbnail \
        --embed-subs \
        --write-info-json \
        --write-comments \
        --write-description \
        --write-thumbnail \
        --embed-thumbnail \
        --write-sub \
        --embed-subs \
        -o "%(title)s [%(id)s] - %(uploader)s - %(upload_date)s.%(ext)s" \
        "$url"
    popd
}

