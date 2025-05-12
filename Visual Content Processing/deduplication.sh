#!/bin/bash

# Find and remove duplicate pictures (exact and perceptual)
# Supports dry-run and no-verbose flags

set -euo pipefail

# === Default Settings ===
DRY_RUN=false
VERBOSE=true
DIRECTORY="."

# ---- Variables ----
TEMP_DIR="$(mktemp -d)"
LOG_FILE="$TEMP_DIR/duplicate_removal.log"
HASH_FILE="$TEMP_DIR/image_hashes.txt"

# === Argument Parsing ===
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --no-verbose) VERBOSE=false ;;
    --verbose) VERBOSE=true ;;
    --*) echo "Unknown option: $arg" >&2; exit 1 ;;
    *) DIRECTORY="$arg" ;;
  esac
done

# === Logging Function ===
log() {
  $VERBOSE && echo "$1"
}

info() {
  $DRY_RUN && echo "[DRY-RUN] $1" || log "$1"
}

# === Cleanup Function (No Residue) ===
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# === Dependency Check ===
check_dependencies() {
  local deps=(fdupes convert md5sum awk grep find exiftool)
  for cmd in "${deps[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "Missing required command: $cmd" >&2
      exit 1
    fi
  done
}

# === Get Perceptual Hash ===
get_phash() {
  convert "$1" -resize 8x8 -colors 2 -depth 8 txt:- 2>/dev/null |
    awk 'NR>1 {print $3}' |
    md5sum | awk '{print $1}' || echo ""
}

# === Histogram Function ===
get_histogram() {
  convert "$1" -format %c -depth 8 histogram:info:- 2>/dev/null |
    awk '{print $1}' | sort | uniq -c | md5sum | awk '{print $1}' || echo ""
}

# === Metadata Hash ===
get_metadata_hash() {
  exiftool "$1" 2>/dev/null | grep -i "Make\|Model\|Date" | tr '\n' ' ' | md5sum | awk '{print $1}' || echo ""
}

# === Exact Duplicate Removal ===
remove_exact_duplicates() {
  log "Removing exact duplicates using fdupes..."
  fdupes -r -N -d "$DIRECTORY" >/dev/null 2>&1 || true
}

# === Perceptual Duplicate Removal ===
remove_visual_duplicates() {
  log "Checking for perceptual/visual duplicates..."
  declare -A seen

  while IFS= read -r -d '' file; do
    [[ ! -r "$file" ]] && continue

    phash=$(get_phash "$file")
    hist=$(get_histogram "$file")
    meta=$(get_metadata_hash "$file")
    sig="${phash}_${hist}_${meta}"

    if [[ -n "${seen[$sig]:-}" ]]; then
      info "Deleting visual duplicate: $file"
      $DRY_RUN || rm -f "$file" 2>/dev/null || true
    else
      seen["$sig"]="$file"
    fi
  done < <(find "$DIRECTORY" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -print0 2>/dev/null)
}

# === Main Script Logic ===
main() {
  check_dependencies
  log "Starting duplicate removal process..."
  remove_exact_duplicates
  remove_visual_duplicates
  echo "Duplicate removal complete."
}

main
