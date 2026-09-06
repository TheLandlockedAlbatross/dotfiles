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
    # Trimming happens LOCALLY in the ffmpeg stage below: --download-sections
    # makes ffmpeg fetch the googlevideo URL itself, which 403s now that PO
    # tokens bind URLs to yt-dlp's client context. Audio is small; grab whole.
    local -a trim cookies
    [[ -n "$start" ]] && trim+=(-ss "$start")
    [[ -n "$end" ]] && trim+=(-to "$end")
    # Age-gated videos: set YTDLP_COOKIE_PROFILE (e.g. "firefox:default-release")
    # in machine-local config (~/.zsh/local.zsh); unset = no cookies, portable.
    [[ -n "${YTDLP_COOKIE_PROFILE}" ]] && cookies=(--cookies-from-browser "${YTDLP_COOKIE_PROFILE}")
    # {} in a custom name expands to the default name (sanitized title, plus
    # the time range when trimming): yt-dlp-OPUS <url> 1:30 4:45 'clips_{}'
    if [[ -z "$name" || "$name" == *"{}"* ]]; then
        local title default_name
        title=$(yt-dlp --get-title --no-playlist "${cookies[@]}" "$url" | head -n 1)
        # Same sanitizer as yt-dlp-FULL_ARCHIVE: alnum, space, _ and - survive
        default_name=$(echo "$title" | tr -cd '[:alnum:] _-' | tr ' ' '_')
        [[ -z "$default_name" ]] && default_name="audio"
        if [[ -n "$start" || -n "$end" ]]; then
            default_name+="_${${start:-0}//:/.}-${${end:-end}//:/.}"
        fi
        if [[ -z "$name" ]]; then
            name="$default_name"
        else
            name="${name//\{\}/$default_name}"
        fi
    fi
    # Two stages: download the canonical best audio stream untouched (whatever
    # codec yt-dlp ranks highest), then make the .opus ourselves with ffmpeg —
    # stream-copied when the source is already Opus, else libopus 192k.
    # mweb client: as of 2026-09, web/web_creator gvs URLs 403 on age-gated
    # data even with valid PO tokens; mweb + cookies + PO provider works.
    # Revisit (drop the extractor-args) when the default client recovers.
    yt-dlp -f bestaudio \
        --embed-metadata \
        --extractor-args "youtube:player_client=mweb" \
        "${cookies[@]}" \
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
    # Stream copy only for whole-file opus: copy-trimming keeps source cluster
    # timestamps and can write negative ogg granules that break players (mpv:
    # "Unsupported huge granule pos"). Trims re-encode: sample-exact cuts,
    # clean timestamps, libopus 192k is transparent.
    if [[ "$codec" == "opus" && ${#trim[@]} -eq 0 ]]; then
        ffmpeg -loglevel error -i "$src" -map_metadata 0 -c:a copy "${name}.opus"
    else
        ffmpeg -loglevel error "${trim[@]}" -i "$src" -map_metadata 0 -c:a libopus -b:a 192k "${name}.opus"
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

