#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

umask 077
export TMPDIR=$(mktemp -d -t scrub_metadata.XXXXXX)
chmod 700 "$TMPDIR"

unset HISTFILE
set +o history

cleanup() {
    rm -rf "$TMPDIR"
}
trap 'cleanup; exit 1' SIGINT SIGTERM EXIT

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <image_directory>" >&2
    cleanup
    exit 1
fi

SOURCE_DIR=$(realpath "$1")
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: '$SOURCE_DIR' is not a valid directory." >&2
    cleanup
    exit 1
fi

for cmd in exiftool convert mat2 sha256sum shred jpegtran pngcrush optipng file srm; do
    if ! command -v "$cmd" &>/dev/null && [[ "$cmd" != "srm" ]]; then
        echo "Error: Required tool '$cmd' is missing. Please install it." >&2
        cleanup
        exit 1
    fi
done

OUTPUT_DIR="$SOURCE_DIR/scrubbed"
mkdir -p "$OUTPUT_DIR"

clear_screen() {
    clear
    echo "Processing images..."
    progress_bar "$1" "$2"
}

progress_bar() {
    local current=$1
    local total=$2
    local term_width bar_width percent progress bar

    term_width=$(tput cols)
    bar_width=$(( term_width / 4 ))   # 25% of terminal width
    (( bar_width < 10 )) && bar_width=10  # minimum width

    percent=$(( 100 * current / total ))
    progress=$(( bar_width * current / total ))
    bar=$(printf "%-${progress}s" "#" | tr ' ' '#')

    # render on single line, overwrite using \r, no newline until complete
    printf "\r[%-${bar_width}s] %3d%% (%d/%d)" "$bar" "$percent" "$current" "$total"
    if (( current == total )); then
        echo ""
    fi
}

secure_delete() {
    shred -u "$1" &>/dev/null || rm -f "$1"
}

check_and_remove_ads() {
    :
}

process_image() {
    local image="$1"
    local base_name
    base_name=$(basename "$image")
    local temp_image="$TMPDIR/$base_name"
    local scrubbed_image="$TMPDIR/scrubbed_$base_name"
    local mime format

    cp "$image" "$temp_image"
    mat2 --inplace "$temp_image" >/dev/null 2>&1 || true
    exiftool -overwrite_original \
        -all= -thumbnailimage= \
        -comment= -xmp:all= -iptc:all= -photoshop:all= \
        -icc_profile= -gps:all= \
        -AllDates="1970:01:01 00:00:00" \
        "$temp_image" >/dev/null 2>&1 || true

    mime=$(file --mime-type -b "$temp_image")
    case "$mime" in
        image/jpeg) format="jpg" ;;
        image/png)  format="png" ;;
        image/webp) format="webp" ;;
        *) rm -f "$temp_image"; return ;;
    esac

    if [[ "$format" == "jpg" ]]; then
        jpegtran -copy none -optimize -perfect "$temp_image" > "$scrubbed_image" 2>/dev/null || cp "$temp_image" "$scrubbed_image"
        exiftool -overwrite_original -icc_profile= "$scrubbed_image" >/dev/null 2>&1 || true
        convert "$scrubbed_image" -strip -colorspace sRGB -quality 85 "$scrubbed_image.tmp" >/dev/null 2>&1 && mv "$scrubbed_image.tmp" "$scrubbed_image"
    elif [[ "$format" == "png" ]]; then
        pngcrush -rem allb -reduce -q "$temp_image" "$scrubbed_image" >/dev/null 2>&1 || cp "$temp_image" "$scrubbed_image"
        optipng -quiet -strip all "$scrubbed_image" >/dev/null 2>&1 || true
        exiftool -overwrite_original -icc_profile= "$scrubbed_image" >/dev/null 2>&1 || true
    elif [[ "$format" == "webp" ]]; then
        convert "$temp_image" -strip -colorspace sRGB -quality 85 "$scrubbed_image" >/dev/null 2>&1
        exiftool -overwrite_original -all= "$scrubbed_image" >/dev/null 2>&1 || true
    fi

    local new_image="$OUTPUT_DIR/$base_name"
    if [[ -f "$new_image" ]]; then
        echo "Warning: '$new_image' already exists — keeping existing, skipping" >&2
        rm -f "$scrubbed_image"
    else
        mv "$scrubbed_image" "$new_image"
    fi

    check_and_remove_ads "$image"
    secure_delete "$image"
    rm -f "$temp_image"
}

mapfile -t images < <(
    find "$SOURCE_DIR" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \)
)
total_images=${#images[@]}

clear
for ((i=0; i<total_images; i++)); do
    process_image "${images[i]}" || echo -e "\nSkipped ${images[i]} due to error."
    if (( i % 2 == 0 )); then  # Update every 2 iterations
        clear_screen $((i+1)) "$total_images"
    fi
    sleep 1  # Adjust the sleep duration as needed
done
echo ""
echo "Scrubbing completed for all $total_images files."
cleanup
exit 0
