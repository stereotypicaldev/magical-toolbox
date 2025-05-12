#!/bin/bash

# Enable strict error handling
set -euo pipefail

# Function to print error message and exit with non-zero status
error_exit() {
  echo "Error: $1"
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
cd "$dir" || exit 1

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
  
  # Validate image exists
  if [[ ! -f "$img" ]]; then
    return 1
  fi

  local base_name=$(basename "$img")

  # Step 1: Remove all metadata and make the image progressive
  jpegoptim --all-progressive --strip-all --max=70 "$img" &>/dev/null || return 1

  # Step 2: Further optimization with jpegoptim
  jpegoptim --strip-all --max=60 "$img" &>/dev/null || return 1

  # Step 3: Additional optimization with advpng (if the image is PNG)
  if [[ "$img" == *.png ]]; then
    advpng -z4 "$img" &>/dev/null || return 1
  fi

  # Step 4: Further optimization with pngcrush (if the image is PNG)
  if [[ "$img" == *.png ]]; then
    pngcrush -rem alla -ow "$img" &>/dev/null || return 1
  fi

  return 0
}

# Loop through each image, optimize it, and show progress on the same line
for ((i = 0; i < total_images; i++)); do
  img="${images[$i]}"
  
  if ! optimize_image "$img"; then
    echo -ne "\nWarning: Skipping image '$img' due to an error.\n"
  fi

  # Print progress on the same line
  echo -ne "Processed $((i + 1))/$total_images: $img\r"
done

# Ensure the last progress message is fully printed
echo -ne "\n"

exit 0
