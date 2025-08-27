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

