#!/bin/bash

# -----------------------------------------------------------------------------
#
# Description: This script scrubs metadata from image files (.jpg, .jpeg, .png, 
#              .gif, .tiff) in the specified directory and renames the images 
#              to unique UUIDs. The script performs the following actions:
#              1. Scrubs metadata using mat2, exiftool, and ImageMagick.
#              2. Renames image files to unique UUIDs to avoid filename collisions.
#
# Usage
#
#   ./scrub_metadata.sh [directory]
#
# Arguments
#
#   directory: Optional. The directory to process. Defaults to the current
#              directory if not provided.
#
# Example:
#
#   ./scrub_metadata.sh /path/to/images
#
# The script will process all images in the provided directory (or the current
# directory by default), scrub their metadata, and rename them to unique UUIDs.
#
# -----------------------------------------------------------------------------

# Get the total number of images to process (only original images)
directory="${1:-.}"
total_images=$(find "$directory" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.tiff" \) | grep -v '\.cleaned' | wc -l)

# Check if there are no images
if [ "$total_images" -eq 0 ]; then
    echo "No images found to process."
    exit 1
fi

# Set up a counter to track progress
counter=0

# Function to display progress bar
show_progress() {
    local progress=$(( ($1 * 100) / $2 ))
    local bar=""
    local width=50
    for ((i=0; i<width; i++)); do
        if [ $i -lt $((progress * width / 100)) ]; then
            bar="${bar}#"
        else
            bar="${bar} "
        fi
    done
    # Print the progress bar with percentage and current photo number
    printf "\r[%-50s] %d%% - Processing image %d of %d" "$bar" "$progress" "$1" "$2"
}

# Function to process an image
process_image() {
    local img="$1"
    local img_basename=$(basename "$img")
    local uuid=$(uuidgen)
    local output="${directory}/${uuid}.jpg"

    # Define temporary filenames
    local temp1="${directory}/temp1_${img_basename}"
    local temp2="${directory}/temp2_${img_basename}"
    local temp3="${directory}/temp3_${img_basename}"

    # Skip if scrubbed image already exists (this should not happen with UUID renaming)
    if [ -f "$output" ]; then
        return 1
    fi

    # Step 1: Copy original image to a temporary file
    cp "$img" "$temp1"

    # Step 2: Use mat2 to remove metadata (suppress output)
    if ! mat2 "$temp1" > /dev/null 2>&1; then
        rm -f "$temp1"
        return 1
    fi
    mv "${temp1%.*}.cleaned.${temp1##*.}" "$temp1"

    # Step 3: Use exiftool to remove all metadata (suppress output)
    if ! exiftool -all= -overwrite_original "$temp1" > /dev/null 2>&1; then
        rm -f "$temp1"
        return 1
    fi
    mv "$temp1" "$temp2"

    # Step 4: Use ImageMagick to strip any remaining metadata (suppress output)
    if ! convert "$temp2" "$temp3" > /dev/null 2>&1; then
        rm -f "$temp2"
        return 1
    fi
    rm -f "$temp2"

    # Step 5: Check if the scrubbed image is the same as the original
    if cmp -s "$img" "$temp3"; then
        rm -f "$temp3"
        return 1
    fi

    # Move the scrubbed image to the original directory with a unique name
    mv "$temp3" "$output"

    # Clean up temporary files
    rm -f "$temp3"

    # Delete the original image to prevent duplicates
    rm -f "$img"

    # Increment progress counter
    ((counter++))
    show_progress "$counter" "$total_images"
}

# Process images sequentially, one by one
find "$directory" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.tiff" \) | grep -v '\.cleaned' | while read img; do
    process_image "$img"
done

# Final message
echo -e "\nMetadata removal complete. Scrubbed images are in the original directory."
