#!/bin/bash

# -----------------------------------------------------------------------------
# Description: This script optimizes image files in the specified directory.
#              It converts JPEG images to progressive format and compresses
#              them using jpegoptim for JPEGs and advpng/pngcrush for PNGs.
#
# -----------------------------------------------------------------------------
# Usage
#
#   ./optimize-filesize.sh [directory]
#
# Arguments
#
#   directory: Optional - The directory to process. Defaults to the current
#              directory if not provided.
#
# Example
#
#   ./optimize-filesize.sh /path/to/images
#
# -----------------------------------------------------------------------------

# Enable strict error handling
set -euo pipefail

# Function to handle and exit on errors with a custom message
error_exit() {
  echo "Error: $1" >&2
  exit 1
}

# Check if required tools are installed
for cmd in jpegoptim advpng pngcrush; do
  command -v "$cmd" >/dev/null 2>&1 || error_exit "$cmd is required but not installed. Please install it before running the script."
done

# Determine the directory to use
dir="${1:-$(pwd)}"

# Check if the directory exists
if [[ ! -d "$dir" ]]; then
  error_exit "Directory '$dir' does not exist."
fi

# Navigate to the specified directory
cd "$dir" || error_exit "Failed to navigate to directory '$dir'."

# Get a list of all the JPEG and PNG files in the directory and subdirectories
images=($(find . -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \)))
total_images=${#images[@]}

# If no images are found, exit
if [[ "$total_images" -eq 0 ]]; then
  error_exit "No images found in directory '$dir'."
fi

# Function to optimize a single image
optimize_image() {
  local img="$1"

  # Ensure the image exists and is a file
  if [[ ! -f "$img" ]]; then
    return 1
  fi

  # Handle JPEG images
  if [[ "$img" == *.jpg || "$img" == *.jpeg ]]; then
    if ! jpegoptim --all-progressive --strip-all --max=70 "$img" &>/dev/null; then
      return 1
    fi
    if ! jpegoptim --strip-all --max=60 "$img" &>/dev/null; then
      return 1
    fi
  fi

  # Handle PNG images
  if [[ "$img" == *.png ]]; then
    if ! advpng -z4 "$img" &>/dev/null; then
      return 1
    fi
    if ! pngcrush -rem alla -ow "$img" &>/dev/null; then
      return 1
    fi
  fi

  return 0
}

# Loop through each image, optimize it, and show progress on the same line
for ((i = 0; i < total_images; i++)); do
  img="${images[$i]}"
  
  if ! optimize_image "$img"; then
    continue  # Skip images that failed to optimize
  fi

  # Print progress on the same line, overwriting previous progress
  echo -ne "Processed $((i + 1))/$total_images: $img\r"
done

# Ensure the last progress message is fully printed
echo -ne "\n"

exit 0
