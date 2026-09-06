# Audio only, best quality, Opus (native stream preferred so opus->opus is a
# copy, not a re-encode). Optional start/end accept any yt-dlp time syntax
# (90, 1:30, 00:01:30.5); omit both for the whole track, omit end to run to
# the end of the video.
#   yt-dlp-OPUS <url> [start] [end]
yt-dlp-OPUS() {
    local url="$1" start="$2" end="$3"
    if [[ -z "$url" ]]; then
        echo "Usage: yt-dlp-OPUS <url> [start] [end]"
        return 1
    fi
    local -a section cookies
    if [[ -n "$start" || -n "$end" ]]; then
        section=(--download-sections "*${start:-0}-${end:-inf}" --force-keyframes-at-cuts)
    fi
    # Age-gated videos: set YTDLP_COOKIE_PROFILE (e.g. "firefox:default-release")
    # in machine-local config (~/.zsh/local.zsh); unset = no cookies, portable.
    [[ -n "${YTDLP_COOKIE_PROFILE}" ]] && cookies=(--cookies-from-browser "${YTDLP_COOKIE_PROFILE}")
    yt-dlp -f "bestaudio[acodec^=opus]/bestaudio" \
        -x --audio-format opus --audio-quality 0 \
        --embed-metadata \
        "${section[@]}" "${cookies[@]}" \
        -o "%(title)s [%(id)s].%(ext)s" \
        "$url"
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

