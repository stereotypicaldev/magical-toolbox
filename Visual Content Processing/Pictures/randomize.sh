#!/bin/bash

# Enforce strict error handling and safe scripting practices
set -euf -o pipefail
IFS=$'\n\t'

# Ensure a directory path is provided
if [ $# -ne 1 ]; then
  echo "Usage: $0 <directory_path>"
  exit 1
fi

# Validate the provided directory
directory="$1"
if [ ! -d "$directory" ]; then
  echo "Error: '$directory' is not a valid directory."
  exit 1
fi

# Function to generate a secure, long UUID with dashes
generate_long_uuid() {
  # Generate 256 random bits and convert to hexadecimal
  local hex
  hex=$(openssl rand -hex 32)

  # Format the hexadecimal string into a UUID-like structure
  echo "${hex:0:8}-${hex:8:4}-${hex:12:4}-${hex:16:4}-${hex:20:12}"
}

# Function to display a progress bar with current file number
show_progress() {
  local current=$1
  local total=$2
  if [ "$total" -gt 0 ]; then
    local percent=$(( 100 * current / total ))
    local bar_length=50
    local filled_length=$(( bar_length * current / total ))
    local empty_length=$(( bar_length - filled_length ))
    local bar
    bar=$(printf "%0.s#" $(seq 1 $filled_length))
    bar+=$(printf "%0.s-" $(seq 1 $empty_length))
    printf "\rProgress: [${bar}] ${percent}%% - File ${current}/${total}"
  fi
}

# Find and process image files in the specified directory only (no subdirectories)
image_files=()
while IFS= read -r -d '' file; do
  image_files+=("$file")
done < <(find "$directory" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -print0)

total_files=${#image_files[@]}

# Check if no image files were found
if [ "$total_files" -eq 0 ]; then
  echo "No image files found in the specified directory."
  exit 0
fi

# Process each image file
for i in "${!image_files[@]}"; do
  file="${image_files[$i]}"
  extension="${file##*.}"
  new_name=$(generate_long_uuid)
  new_file="${file%/*}/$new_name.$extension"

  # Check if the new file name already exists
  if [ -e "$new_file" ]; then
    continue
  fi

  # Rename the file
  mv "$file" "$new_file"

  # Display progress
  show_progress $((i + 1)) $total_files
done

# Clear the terminal line after completion
echo -e "\n"
