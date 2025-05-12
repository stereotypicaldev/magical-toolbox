#!/bin/bash

# Enable strict error handling
set -euo pipefail

# Determine the directory to use
dir="${1:-$(pwd)}"

# Navigate to the specified directory
cd "$dir" || exit

# Create the scrubbed_images directory if it doesn't exist
mkdir -p scrubbed_images

# Function to optimize a single JPEG image
optimize_image() {
  local img="$1"
  local base_name=$(basename "$img")
  local scrubbed_img="scrubbed_images/$base_name"

  # Step 1: Remove all metadata and make the image progressive
  jpegoptim --all-progressive --strip-all --max=70 --dest=scrubbed_images "$img" &>/dev/null

  # Step 2: Further optimization with jpegoptim
  jpegoptim --strip-all --max=60 --dest=scrubbed_images "$scrubbed_img" &>/dev/null

  # Step 3: Additional optimization with advpng
  advpng -z4 "$scrubbed_img" &>/dev/null

  # Step 4: Further optimization with pngcrush
  pngcrush -rem alla -ow "$scrubbed_img" &>/dev/null

  # Final output: Check if the source and destination are the same before moving
  if [[ "$img" != "$scrubbed_img" ]]; then
    mv -f "$scrubbed_img" "$scrubbed_img" &>/dev/null
  fi
}

export -f optimize_image

# Process each JPEG image in the directory and its subdirectories
find . -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) -exec bash -c 'optimize_image "$0"' {} \;

exit 0
