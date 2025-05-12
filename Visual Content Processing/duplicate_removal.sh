#!/bin/bash

# -----------------------------------------------------------------------------
# Description: Removes exact and perceptual image duplicates from a specified 
#              directory (or current directory by default).
#
# Usage
#
#   ./duplicate_removal.sh [directory]
#
# Arguments
#
#   directory: Optional - Defaults to the current directory if not provided.
#
# Example
#
#   ./duplicate_removal.sh /path/to/images
#
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# Default settings
DIRECTORY="${1:-.}"
DELETED_COUNT=0
TEMP_DIR=$(mktemp -d)
LOG_FILE="$TEMP_DIR/duplicate_removal.log"

# Ensure cleanup on exit
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Logging function
log() {
  echo "$1" | tee -a "$LOG_FILE"
}

# Check for required dependencies
check_dependencies() {
  local deps=(fdupes convert md5sum awk grep exiftool)
  for cmd in "${deps[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      log "Missing required command: $cmd"
      exit 1
    fi
  done
}

# Generate perceptual hash for image
get_phash() {
  convert "$1" -resize 8x8 -colors 2 -depth 8 txt:- 2>/dev/null |
    awk 'NR>1 {print $3}' |
    md5sum | awk '{print $1}' || echo ""
}

# Generate histogram hash for image
get_histogram() {
  convert "$1" -format %c -depth 8 histogram:info:- 2>/dev/null |
    awk '{print $1}' | sort | uniq -c | md5sum | awk '{print $1}' || echo ""
}

# Generate metadata hash for image
get_metadata_hash() {
  exiftool "$1" 2>/dev/null | grep -i "Make\|Model\|Date" | tr '\n' ' ' | md5sum | awk '{print $1}' || echo ""
}

# Remove exact duplicates using fdupes
remove_exact_duplicates() {
  log "Removing exact duplicates using fdupes..."
  local deleted
  deleted=$(fdupes -r -N -d "$DIRECTORY" | grep -c "^$")
  DELETED_COUNT=$((DELETED_COUNT + deleted))
  log "Exact duplicates removed: $deleted"
}

# Remove perceptual duplicates based on image hashes
remove_visual_duplicates() {
  log "Checking for perceptual/visual duplicates..."
  declare -A seen

  for file in "$DIRECTORY"/**/*.{jpg,jpeg,png}; do
    [[ ! -r "$file" ]] && continue

    # Generate image hashes
    phash=$(get_phash "$file")
    hist=$(get_histogram "$file")
    meta=$(get_metadata_hash "$file")
    sig="${phash}_${hist}_${meta}"

    # Check if the image signature has already been seen
    if [[ -n "${seen[$sig]:-}" ]]; then
      log "Deleting visual duplicate: $file"
      rm -f "$file" 2>/dev/null || true
      DELETED_COUNT=$((DELETED_COUNT + 1))
    else
      seen["$sig"]="$file"
    fi
  done
}

# Main execution logic
main() {
  check_dependencies
  log "Starting duplicate removal process..."

  # Step 1: Remove exact duplicates
  remove_exact_duplicates

  # Step 2: Remove perceptual duplicates
  remove_visual_duplicates

  # Final summary
  log "Duplicate removal complete. Total files deleted: $DELETED_COUNT"
}

# Run the main function
main
