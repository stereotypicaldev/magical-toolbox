#!/bin/bash

# Enable strict mode for robust error handling
set -euo pipefail
IFS=$'\n\t'

# Ensure secure umask and create a temporary directory with restricted access
umask 0770
export TMPDIR=$(mktemp -d -t scrub_metadata.XXXXXX)
chmod 700 "$TMPDIR"

# Disable history logging and suppress all output
unset HISTFILE
set +o history

# Function to securely remove temporary files and scrub any traces
cleanup() {
    rm -rf "$TMPDIR"
}

# Trap errors and ensure cleanup on exit (including on user interrupt)
trap 'cleanup; exit 1' SIGINT SIGTERM EXIT

# Validate input directory
SOURCE_DIR=$(realpath "$1")
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: '$SOURCE_DIR' is not a valid directory."
    exit 1
fi

# Check for required tools and ensure they are installed
for cmd in exiftool convert mat2 sha256sum; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required tool '$cmd' is missing. Please install it."
        exit 1
    fi
done

# Function to process each image
process_image() {
    local image="$1"
    local image_filename
    image_filename=$(basename "$image")
    local temp_image="$TMPDIR/$image_filename"
    local final_image="$TMPDIR/final_$image_filename"

    # Step 1: Copy image to temporary location
    cp "$image" "$temp_image"

    # Step 2: Strip metadata using mat2
    mat2 --inplace "$temp_image" > /dev/null 2>&1

    # Step 3: Remove GPS information using ExifTool
    exiftool -gps:all= "$temp_image" > /dev/null 2>&1

    # Step 4: Anonymize timestamps using ExifTool
    exiftool -AllDates="1970:01:01 00:00:00" "$temp_image" > /dev/null 2>&1

    # Step 5: Re-encode image to ensure it's a clean sRGB image
    convert "$temp_image" -resize 100% -colorspace sRGB "$final_image" > /dev/null 2>&1

    # Step 6: Strip metadata again after re-encoding using ExifTool
    exiftool -overwrite_original -quiet -all= -icc_profile= "$final_image" > /dev/null 2>&1

    # Step 7: Generate SHA-256 hash of the final image content
    local image_hash
    image_hash=$(sha256sum "$final_image" | awk '{print $1}')

    # Commented out the hash message
    # echo "SHA-256 Hash: $image_hash"

    # Step 8: Rename the image to its hash value
    local new_image="$SOURCE_DIR/$image_hash.jpg"
    if [[ -f "$new_image" ]]; then
        echo "Warning: A file with hash $image_hash already exists, skipping this image."
    else
        mv -f "$final_image" "$new_image"
        mv -f "$new_image" "$image"
    fi

    # Step 9: Cleanup temporary files securely
    rm -f "$temp_image" "$final_image"
}

# Start processing the images
total_images=$(find "$SOURCE_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) | wc -l)
current_image=0

# Clear the terminal screen at the start
clear

# Process images one by one
find "$SOURCE_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) | while IFS= read -r image; do
    current_image=$((current_image + 1))

    # Create progress bar (for the terminal, avoid creating files)
    progress=$((current_image * 100 / total_images))
    progress_bar=$(printf "%-${progress}s" "#" | tr ' ' '#')
    spaces=$(printf "%-$((100 - progress))s")

    # Print progress bar without tput (simpler method)
    echo -ne "Processing $current_image out of $total_images: "
    echo -ne "\033[32m$progress_bar$spaces\033[0m $progress%"

    # Process the image
    process_image "$image"

    # Clear the progress bar after each update
    echo -ne "\r\033[K"  # Clear the line
done

# Final cleanup and script exit
cleanup

# Final message after processing
echo -e "\nMetadata scrub process completed for all files."

exit 0
