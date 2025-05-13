#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Temporary file handling
TMP_FILES=""

# Error and security handling
error_exit() {
    echo "$1" >&2
    exit 1
}

# Trap to clean up temp files on exit or interruption
cleanup() {
    if [[ -n "${TMP_FILES:-}" ]]; then
        rm -f $TMP_FILES 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Securely process one image with layered anonymization
process_image() {
    local original="$1"
    local ext="${original##*.}"
    local filename="$(basename "$original")"

    # Create 4 chained temp files
    local tmp1 tmp2 tmp3 tmp4
    tmp1=$(mktemp --suffix=".$ext") || error_exit "Failed to create temporary file 1."
    tmp2=$(mktemp --suffix=".$ext") || error_exit "Failed to create temporary file 2."
    tmp3=$(mktemp --suffix=".$ext") || error_exit "Failed to create temporary file 3."
    tmp4=$(mktemp --suffix=".$ext") || error_exit "Failed to create temporary file 4."
    TMP_FILES="$tmp1 $tmp2 $tmp3 $tmp4"

    # Ensure the original image is readable and writable
    [[ ! -r "$original" ]] && error_exit "Cannot read the original file: $original"
    [[ ! -w "$original" ]] && error_exit "Cannot write to the original file: $original"

    cp -- "$original" "$tmp1" || error_exit "Failed to copy the original file to temporary storage."

    # Step 1: Remove all metadata with exiftool
    exiftool -overwrite_original -all= "$tmp1" >/dev/null 2>&1 || error_exit "Failed to remove metadata with exiftool."

    # Step 2: Strip ICC profiles, thumbnails, comments using convert
    convert "$tmp1" -strip "$tmp2" 2>/dev/null || error_exit "Failed to strip image metadata using convert."

    # Step 3: Optimize JPEG (if applicable)
    if [[ "$ext" =~ ^[jJ][pP][eE]?[gG]$ ]]; then
        cp "$tmp2" "$tmp3"
        jpegoptim --quiet --strip-all --max=85 "$tmp3" >/dev/null 2>&1 || error_exit "Failed to optimize JPEG: $tmp3"
    else
        cp "$tmp2" "$tmp3"
    fi

    # Step 4: Deep anonymization using MAT2
    cp "$tmp3" "$tmp4"
    mat2 --inplace "$tmp4" >/dev/null 2>&1 || error_exit "Failed to anonymize the file using MAT2."

    # Step 5: Remove JPEG-specific GPS/location data
    if [[ "$ext" =~ ^[jJ][pP][eE]?[gG]$ ]]; then
        jhead -purejpg "$tmp4" >/dev/null 2>&1 || error_exit "Failed to remove GPS/location data with jhead."
    fi

    # Only after all steps succeed, replace original
    cp -- "$tmp4" "$original" || error_exit "Failed to overwrite original file with anonymized version."

    # Clean up temp files explicitly
    rm -f "$tmp1" "$tmp2" "$tmp3" "$tmp4"
    TMP_FILES=""
}

# Graphical progress bar
draw_progress_bar() {
    local current="$1"
    local total="$2"
    local file="$3"
    local width=30
    local percent=$((100 * current / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    local bar
    bar="$(printf "%0.s█" $(seq 1 $filled))"
    bar+="$(printf "%0.s░" $(seq 1 $empty))"
    printf "\r\033[KProgress: [%s] %3d%% (%d/%d) Processing: %s" \
        "$bar" "$percent" "$current" "$total" "$(basename "$file")"
}

# Process all images recursively
scrub_metadata() {
    local dir="$1"
    [[ ! -d "$dir" ]] && error_exit "'$dir' is not a directory."

    # Find image files
    mapfile -t images < <(find "$dir" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.tiff" \))
    local total="${#images[@]}"
    [[ "$total" -eq 0 ]] && echo "No images found." && exit 0

    echo "Found $total image(s). Starting metadata scrub..."
    local count=0

    for file in "${images[@]}"; do
        count=$((count + 1))
        draw_progress_bar "$count" "$total" "$file"
        if ! process_image "$file"; then
            printf "\nWarning: Failed to scrub %s\n" "$file" >&2
        fi
    done

    printf "\r\033[KMetadata scrubbing complete.\n"
}

# Entry point
main() {
    [[ $# -ne 1 ]] && echo "Usage: $0 <directory>" >&2 && exit 1
    scrub_metadata "$1"
}

main "$@"
