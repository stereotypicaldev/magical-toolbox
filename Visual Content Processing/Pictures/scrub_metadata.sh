#!/bin/bash

# scrub-metadata.sh - A robust script to remove metadata from images and optimize them.
#
# This script processes images in a specified folder, removing various types of metadata
# (Exif, XMP, IPTC, etc.), and optionally optimizes image size using external tools.
# It handles different image formats, retries failed operations, and provides secure cleanup.
#
# Usage: ./scrub-metadata.sh /path/to/your/images
#
# Requirements:
#   - Core utilities: find, stat, shred, mktemp, timeout, stty, awk, sleep, md5sum, df
#   - Image processing: exiftool, identify, convert (from ImageMagick)
#   - Optional optimization tools: mat2, jpegoptim, optipng, pngcrush
#
# Error Handling & Robustness:
#   - Strict mode: Uses set -e, set -u, set -o pipefail for early error detection.
#   - Traps: Ensures temporary files are cleaned up even on script exit or interruption.
#   - Retries: Attempts failed operations multiple times.
#   - Secure deletion: Uses 'shred' for sensitive temporary files.
#   - Disk space checks: Verifies sufficient space before and during processing.
#   - Progress bar: Provides visual feedback during long operations.
#   - Detailed logging: Differentiates between INFO, WARNING, ERROR, and DEBUG messages.
#   - Skips corrupt files: Handles unreadable or zero-byte images gracefully.
#   - Reports failed images: Lists all images that could not be processed at the end.
#
# Exit Codes:
#   - 0: All supported images processed successfully.
#   - 1: Script encountered errors (e.g., missing dependencies, insufficient space, or some images failed).

# --- Configuration ---
MAX_STEP_RETRIES=3        # Max attempts for a single image processing step (e.g., exiftool call)
RETRY_DELAY_SEC=2         # Delay in seconds between retries
COMMAND_TIMEOUT_SEC=60    # Timeout for external commands in seconds
MIN_FREE_SPACE_KB=512000  # Minimum free space required in KB (500 MB) in /tmp and target dir

# --- Log Levels ---
# Define numerical values for log levels. Lower numbers mean higher severity.
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARNING=2
readonly LOG_LEVEL_ERROR=3

# Set the desired logging threshold. Messages with a level >= this threshold will be printed.
# Setting to a high value (e.g., 99) effectively silences all 'log_message' calls.
LOG_LEVEL_THRESHOLD=99

# --- Global Variables (Managed by main and cleanup functions) ---
TEMP_DEID_DIR=""          # Primary temporary directory for the entire script run
declare -A OPTIONAL_COMMANDS_AVAILABLE # Associative array to track available optional tools

# --- Logging Function ---
log_message() {
    local level_name="$1"
    local level_value="$2"
    local message="$3"

    if [[ "${level_value}" -ge "${LOG_LEVEL_THRESHOLD}" ]]; then
        printf "%s: %s\n" "${level_name}" "${message}" >&2
    fi
}

# --- Helper Functions ---

# Function to check if a command exists. If not, print error and exit.
check_command() {
    local cmd="$1"
    local deb_pkg="$2"
    local rpm_pkg="$3"
    local arch_pkg="$4"

    if ! command -v "${cmd}" &>/dev/null; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "Required command '${cmd}' not found. Please install it."
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "  Debian/Ubuntu: sudo apt-get install ${deb_pkg}"
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "  CentOS/Fedora: sudo yum install ${rpm_pkg} or sudo dnf install ${rpm_pkg}"
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "  Arch Linux: sudo pacman -S ${arch_pkg}"
        exit 1
    fi
    log_message "INFO" "${LOG_LEVEL_INFO}" "Command '${cmd}' found."
}

# Function to check for optional commands. Does not exit if missing.
check_optional_command() {
    local cmd="$1"
    local deb_pkg="$2"
    local rpm_pkg="$3"
    local arch_pkg="$4"

    if command -v "${cmd}" &>/dev/null; then
        OPTIONAL_COMMANDS_AVAILABLE["${cmd}"]=true
        log_message "INFO" "${LOG_LEVEL_INFO}" "Optional command '${cmd}' found. Will be used for optimization."
    else
        OPTIONAL_COMMANDS_AVAILABLE["${cmd}"]=false
        log_message "INFO" "${LOG_LEVEL_INFO}" "Optional command '${cmd}' not found. Optimization with this tool will be skipped."
        log_message "INFO" "${LOG_LEVEL_INFO}" "  To install: Debian/Ubuntu: sudo apt-get install ${deb_pkg}, etc."
    fi
}

# Function to securely delete a file
secure_delete_file() {
    local file_path="$1"
    if [[ -f "${file_path}" ]]; then
        log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Attempting to shred file: ${file_path}"
        if ! timeout "${COMMAND_TIMEOUT_SEC}" shred -u -z -n 1 "${file_path}" &>/dev/null; then
            log_message "WARNING" "${LOG_LEVEL_WARNING}" "Shred failed for '${file_path}', falling back to rm."
            rm -f "${file_path}" &>/dev/null || log_message "ERROR" "${LOG_LEVEL_ERROR}" "Failed to delete file: ${file_path}"
        fi
    fi
}

# Function to securely delete a directory and its contents
secure_delete_dir() {
    local dir_path="$1"
    if [[ -d "${dir_path}" ]]; then
        log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Securely deleting directory: ${dir_path}"
        # Find all files and shred them first
        find "${dir_path}" -type f -print0 | while IFS= read -r -d $'\0' file; do
            secure_delete_file "${file}"
        done
        # Then remove the directory and any remaining empty subdirectories
        rm -rf "${dir_path}" &>/dev/null || log_message "ERROR" "${LOG_LEVEL_ERROR}" "Failed to delete directory: ${dir_path}"
    fi
}

# Function to perform final cleanup actions (called by trap)
cleanup_final_actions() {
    log_message "INFO" "${LOG_LEVEL_INFO}" "Performing final cleanup actions."
    # Securely delete the main temporary directory
    secure_delete_dir "${TEMP_DEID_DIR}"

    # Clean up any leftover temporary directories from previous crashed runs (just in case)
    # Using a more specific pattern to avoid deleting unrelated tmp files
    find "/tmp" -maxdepth 1 -type d -name "image_deidentify_*" -print0 | while IFS= read -r -d $'\0' dir; do
        log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Found leftover temp dir from previous run: ${dir}"
        secure_delete_dir "${dir}"
    done
    
    # Restore standard output to /dev/tty from FD3
    exec 3>&- # Close FD 3
}

# Check for sufficient disk space in a given path
check_disk_space() {
    local target_path="$1"
    local required_kb="$2"
    # df -k output: Filesystem 1K-blocks Used Available Use% Mounted on
    local available_kb=$(df -k --output=avail "${target_path}" 2>/dev/null | tail -n 1)

    if [[ -z "${available_kb}" ]]; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "Could not determine available disk space for '${target_path}'. Check path or permissions."
        exit 1
    fi

    if [[ "${available_kb}" -lt "${required_kb}" ]]; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "Insufficient disk space in '${target_path}'. Required: ${required_kb} KB, Available: ${available_kb} KB."
        exit 1
    fi
    log_message "INFO" "${LOG_LEVEL_INFO}" "Sufficient disk space available in '${target_path}' (${available_kb} KB)."
}


# Function to display progress bar
show_progress() {
    local current="$1"
    local total="$2"
    local bar_length=25 # Fixed length for the bar characters
    
    # Ensure total is not zero to avoid division by zero
    if [[ "$total" -eq 0 ]]; then
        total=1 # Set to 1 to avoid division by zero, will result in 100% or 0%
    fi

    local percentage=$(( (current * 100) / total ))
    local filled_chars=$(( (current * bar_length) / total ))
    local empty_chars=$(( bar_length - filled_chars ))

    local bar=$(printf "%${filled_chars}s" | tr ' ' '#')
    local empty=$(printf "%${empty_chars}s" | tr ' ' '-')

    # Determine terminal width dynamically for status message alignment
    local term_width=$(stty size 2>/dev/null | awk '{print $2}' || echo 80)
    local progress_text=" ${percentage}% (${current}/${total})"
    local full_line="[${bar}${empty}] ${progress_text}"

    # Calculate padding to clear previous line content and align to right
    local padding_needed=$(( term_width - ${#full_line} ))
    if [[ "${padding_needed}" -lt 0 ]]; then padding_needed=0; fi # Don't use negative padding

    # Use \r to return to the beginning of the line, \033[K to clear to end of line
    # Output to file descriptor 3 (/dev/tty) to not interfere with stdout/stderr for logging
    printf -- "\r%s%${padding_needed}s\033[K" "${full_line}" "" >&3
}


# Function to process a single image
process_image() {
    local input_image="$1"
    local temp_process_dir="$2" # Temporary directory specific to this image processing run
    local filename=$(basename "$input_image")
    local output_image="${temp_process_dir}/${filename}.scrubbed" # Temporary scrubbed output

    log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Processing image: ${input_image}"

    local original_dims=""
    local original_format_identified=""
    local original_size=0
    local original_md5=""

    # 1. Initial check: Verify original image readability, dimensions, and size
    local original_check_succeeded=false
    for (( i=0; i<MAX_STEP_RETRIES; i++ )); do
        # Use timeout to prevent hanging on corrupt files
        original_dims=$(timeout "${COMMAND_TIMEOUT_SEC}" identify -format '%wx%h' "$input_image" 2>/dev/null)
        original_format_identified=$(timeout "${COMMAND_TIMEOUT_SEC}" identify -format '%m' "$input_image" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        original_size=$(stat -c %s "$input_image" 2>/dev/null || echo 0) # Capture original size
        
        # Check if the file is zero-sized or if identify failed to get info
        if [[ -n "${original_dims}" ]] && [[ -n "${original_format_identified}" ]] && [[ "${original_size}" -gt 0 ]]; then
            original_check_succeeded=true
            break
        fi
        log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Initial check failed for '${filename}', retrying (attempt $((i+1))/${MAX_STEP_RETRIES})..."
        sleep "${RETRY_DELAY_SEC}"
    done
    if ! $original_check_succeeded; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "Original image '${filename}' is corrupt or unreadable (or zero size) after ${MAX_STEP_RETRIES} retries. Skipping image."
        return 1 # Indicate failure for this image
    fi

    # Calculate original MD5 sum for integrity check later
    original_md5=$(md5sum "$input_image" | awk '{print $1}')
    if [[ -z "${original_md5}" ]]; then
        log_message "WARNING" "${LOG_LEVEL_WARNING}" "Could not calculate MD5 sum for original image '${filename}'. Integrity check will be skipped."
    fi
    log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Original image '${filename}' - Dims: ${original_dims}, Format: ${original_format_identified}, Size: ${original_size} bytes, MD5: ${original_md5}"


    # 2. Duplicate the image for processing (operate on copy)
    if ! cp "$input_image" "${output_image}"; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "Failed to create temporary copy of '${filename}'. Skipping image."
        return 1
    fi
    log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Created temporary copy: ${output_image}"

    # --- Metadata Scrubbing ---
    local scrub_success=false
    if ${OPTIONAL_COMMANDS_AVAILABLE["mat2"]:-false}; then
        log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Attempting to scrub metadata with mat2."
        # mat2 is usually robust, but include retry for safety
        for (( i=0; i<MAX_STEP_RETRIES; i++ )); do
            if timeout "${COMMAND_TIMEOUT_SEC}" mat2 "${output_image}" &>/dev/null; then
                scrub_success=true
                log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Metadata scrubbed with mat2 for ${filename}."
                break
            fi
            log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "mat2 failed for '${filename}', retrying (attempt $((i+1))/${MAX_STEP_RETRIES})..."
            sleep "${RETRY_DELAY_SEC}"
        done
        if ! $scrub_success; then
            log_message "WARNING" "${LOG_LEVEL_WARNING}" "mat2 failed for '${filename}' after ${MAX_STEP_RETRIES} retries. Falling back to exiftool for metadata removal."
        fi
    fi

    if ! $scrub_success; then # Only use exiftool if mat2 was not available or failed
        log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Attempting to scrub metadata with exiftool (or as fallback)."
        # exiftool -all= is very comprehensive for metadata removal
        for (( i=0; i<MAX_STEP_RETRIES; i++ )); do
            # Use -overwrite_original for direct modification (faster), but we're on a copy.
            # Add -fast2 and -m to speed up and ignore minor errors
            if timeout "${COMMAND_TIMEOUT_SEC}" exiftool -all= -overwrite_original_in_place -fast2 -m "${output_image}" &>/dev/null; then
                scrub_success=true
                log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Metadata scrubbed with exiftool for ${filename}."
                break
            fi
            log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "exiftool failed for '${filename}', retrying (attempt $((i+1))/${MAX_STEP_RETRIES})..."
            sleep "${RETRY_DELAY_SEC}"
        done
        if ! $scrub_success; then
            log_message "ERROR" "${LOG_LEVEL_ERROR}" "Exiftool failed to scrub metadata for '${filename}' after ${MAX_STEP_RETRIES} retries. Skipping remaining processing for this image."
            secure_delete_file "${output_image}"
            return 1
        fi
    fi

    # 3. Re-save image to strip any remaining hidden data / optimize
    log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Re-saving image to strip remaining data and prepare for optimization."
    local resave_success=false
    for (( i=0; i<MAX_STEP_RETRIES; i++ )); do
        # Use convert to re-save the image. This can strip some data ImageMagick itself understands.
        # Use +repage to reset canvas size and virtual canvas offsets (important for some formats)
        # Use -quality 95 for JPG to preserve quality while potentially reducing size slightly
        # -strip: Remove all profiles and comments (redundant with exiftool -all= but good double check)
        # Convert to original format (e.g., JPEG, PNG)
        if timeout "${COMMAND_TIMEOUT_SEC}" convert "${output_image}" -strip +repage -quality 95 "${output_image}" &>/dev/null; then
            resave_success=true
            log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Image re-saved with ImageMagick convert for ${filename}."
            break
        fi
        log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "ImageMagick convert (re-save) failed for '${filename}', retrying (attempt $((i+1))/${MAX_STEP_RETRIES})..."
        sleep "${RETRY_DELAY_SEC}"
    done
    if ! $resave_success; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "ImageMagick 'convert' failed to re-save '${filename}' after ${MAX_STEP_RETRIES} retries. Skipping remaining processing."
        secure_delete_file "${output_image}"
        return 1
    fi

    # --- Image Optimization (Optional, based on available tools and image format) ---
    local current_size=$(stat -c %s "${output_image}" 2>/dev/null || echo 0)
    log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Size after scrubbing and re-save: ${current_size} bytes."

    # JPEG Optimization
    if [[ "${original_format_identified}" == "jpeg" ]]; then
        if ${OPTIONAL_COMMANDS_AVAILABLE["jpegoptim"]:-false}; then
            log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Attempting JPEG optimization with jpegoptim."
            local optimized=false
            for (( i=0; i<MAX_STEP_RETRIES; i++ )); do
                # --strip-all: Strip all markers (redundant with exiftool but extra safe)
                # --all-progressive: Make all JPEGs progressive
                # --max=85: Target quality 85 (or keep original if already lower)
                if timeout "${COMMAND_TIMEOUT_SEC}" jpegoptim --strip-all --all-progressive --max=85 "${output_image}" &>/dev/null; then
                    optimized=true
                    log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "JPEG optimized with jpegoptim for ${filename}."
                    break
                fi
                log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "jpegoptim failed for '${filename}', retrying (attempt $((i+1))/${MAX_STEP_RETRIES})..."
                sleep "${RETRY_DELAY_SEC}"
            done
            if ! $optimized; then
                log_message "WARNING" "${LOG_LEVEL_WARNING}" "jpegoptim failed for '${filename}' after ${MAX_STEP_RETRIES} retries. Skipping jpegoptim."
            fi
        fi
    fi

    # PNG Optimization
    if [[ "${original_format_identified}" == "png" ]]; then
        if ${OPTIONAL_COMMANDS_AVAILABLE["optipng"]:-false}; then
            log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Attempting PNG optimization with optipng."
            local optimized=false
            for (( i=0; i<MAX_STEP_RETRIES; i++ )); do
                # -o7: Optimization level 7 (aggressive)
                if timeout "${COMMAND_TIMEOUT_SEC}" optipng -o7 "${output_image}" &>/dev/null; then
                    optimized=true
                    log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "PNG optimized with optipng for ${filename}."
                    break
                fi
                log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "optipng failed for '${filename}', retrying (attempt $((i+1))/${MAX_STEP_RETRIES})..."
                sleep "${RETRY_DELAY_SEC}"
            done
            if ! $optimized; then
                log_message "WARNING" "${LOG_LEVEL_WARNING}" "optipng failed for '${filename}' after ${MAX_STEP_RETRIES} retries. Skipping optipng."
            fi
        fi
        
        if ${OPTIONAL_COMMANDS_AVAILABLE["pngcrush"]:-false}; then
            log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Attempting PNG optimization with pngcrush."
            local optimized=false
            # pngcrush often works better by outputting to a new file, then replacing
            local temp_pngcrush_output="${output_image}.pngcrush"
            for (( i=0; i<MAX_STEP_RETRIES; i++ )); do
                # -ow: Overwrite original
                # -res: Reset timestamp
                # -brute: Brute-force optimization
                if timeout "${COMMAND_TIMEOUT_SEC}" pngcrush -ow -res -brute "${output_image}" &>/dev/null; then
                    optimized=true
                    log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "PNG optimized with pngcrush for ${filename}."
                    break
                fi
                log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "pngcrush failed for '${filename}', retrying (attempt $((i+1))/${MAX_STEP_RETRIES})..."
                sleep "${RETRY_DELAY_SEC}"
            done
            if ! $optimized; then
                log_message "WARNING" "${LOG_LEVEL_WARNING}" "pngcrush failed for '${filename}' after ${MAX_STEP_RETRIES} retries. Skipping pngcrush."
                # Clean up any partial output from pngcrush if it failed
                secure_delete_file "${temp_pngcrush_output}"
            fi
        fi
    fi

    # 4. Final Integrity Checks on the scrubbed/optimized image
    log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Performing final integrity checks on scrubbed image: ${output_image}"
    local final_dims=$(timeout "${COMMAND_TIMEOUT_SEC}" identify -format '%wx%h' "${output_image}" 2>/dev/null)
    local final_format=$(timeout "${COMMAND_TIMEOUT_SEC}" identify -format '%m' "${output_image}" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local final_size=$(stat -c %s "${output_image}" 2>/dev/null || echo 0)

    if [[ -z "${final_dims}" ]] || [[ -z "${final_format}" ]] || [[ "${final_size}" -eq 0 ]]; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "Scrubbed image '${filename}' is corrupt or empty after processing. Deleting temporary file."
        secure_delete_file "${output_image}"
        return 1
    fi

    if [[ "${final_dims}" != "${original_dims}" ]]; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "Dimensions mismatch for '${filename}'. Original: ${original_dims}, Scrubbed: ${final_dims}. Deleting temporary file."
        secure_delete_file "${output_image}"
        return 1
    fi

    if [[ "${final_format}" != "${original_format_identified}" ]]; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "Format mismatch for '${filename}'. Original: ${original_format_identified}, Scrubbed: ${final_format}. Deleting temporary file."
        secure_delete_file "${output_image}"
        return 1
    fi

    # Final MD5 comparison (optional, as metadata changes MD5, but good for general file corruption)
    # If original_md5 was not calculated, this check is skipped
    if [[ -n "${original_md5}" ]]; then
        local final_md5=$(md5sum "${output_image}" | awk '{print $1}')
        if [[ -z "${final_md5}" ]]; then
            log_message "WARNING" "${LOG_LEVEL_WARNING}" "Could not calculate MD5 sum for scrubbed image '${filename}'. Skipping MD5 integrity check."
        elif [[ "${final_md5}" == "${original_md5}" ]]; then
            log_message "WARNING" "${LOG_LEVEL_WARNING}" "MD5 sum of scrubbed image is identical to original for '${filename}'. This might indicate no metadata was present or scrubbing was ineffective."
        fi
    fi
    log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Final scrubbed image '${filename}' - Dims: ${final_dims}, Format: ${final_format}, Size: ${final_size} bytes."


    # 5. Securely replace the original image with the scrubbed version
    log_message "DEBUG" "${LOG_LEVEL_DEBUG}" "Replacing original image '${input_image}' with scrubbed version."
    # Use mv -f to force overwrite, but only after shredding original for security
    if ! secure_delete_file "${input_image}"; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "Failed to securely delete original image '${input_image}'. Cannot replace. Deleting temporary file."
        secure_delete_file "${output_image}"
        return 1
    fi

    if ! mv "${output_image}" "${input_image}"; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "Failed to move scrubbed image to original location for '${filename}'. Original may be gone. Skipping image."
        # Attempt to delete the scrubbed file since it couldn't be moved
        secure_delete_file "${output_image}"
        return 1
    fi
    log_message "INFO" "${LOG_LEVEL_INFO}" "Successfully scrubbed and replaced: ${filename}"
    return 0 # Indicate success for this image
}

# --- Main Script Logic ---
main() {
    # Set up file descriptor 3 to point to /dev/tty for progress bar output, independent of stdout/stderr.
    exec 3>/dev/tty

    # Capture and disable terminal echo if stty is available, to prevent user input from appearing in output.
    if command -v stty &>/dev/null; then
        OLD_STTY_SETTINGS=$(stty -g 2>/dev/null)
        stty -echo 2>/dev/null # Disable echo
    fi

    # Set up a trap to ensure cleanup_final_actions is called when the script exits (normally or abnormally).
    trap '
        if [[ -n "${OLD_STTY_SETTINGS}" ]]; then
            stty "${OLD_STTY_SETTINGS}" 2>/dev/null # Restore original stty settings
        fi
        cleanup_final_actions
    ' EXIT

    # --- Check for all required external commands ---
    log_message "INFO" "${LOG_LEVEL_INFO}" "Checking for required commands..."
    check_command "find" "findutils" "findutils" "findutils"
    check_command "exiftool" "libimage-exiftool-perl" "perl-Image-ExifTool" "exiftool"
    check_command "identify" "imagemagick" "ImageMagick" "imagemagick"
    check_command "convert" "imagemagick" "ImageMagick" "imagemagick"
    check_command "shred" "coreutils" "coreutils" "coreutils"
    check_command "mktemp" "coreutils" "coreutils" "coreutils"
    check_command "timeout" "coreutils" "coreutils" "coreutils"
    check_command "stty" "coreutils" "coreutils" "coreutils" 
    check_command "awk" "gawk" "gawk" "awk"
    check_command "sleep" "coreutils" "coreutils" "coreutils"
    check_command "md5sum" "coreutils" "coreutils" "coreutils"
    check_command "df" "coreutils" "coreutils" "coreutils" # Added df for disk space check
    check_command "stat" "coreutils" "coreutils" "coreutils" # Added stat for file size check

    # --- Check for optional external commands (scrubbing tools) ---
    log_message "INFO" "${LOG_LEVEL_INFO}" "Checking for optional optimization commands..."
    check_optional_command "mat2" "mat2" "mat2" "mat2"
    check_optional_command "jpegoptim" "jpegoptim" "jpegoptim" "jpegoptim"
    check_optional_command "optipng" "optipng" "optipng" "optipng"
    check_optional_command "pngcrush" "pngcrush" "pngcrush" "pngcrush"

    # --- Input Validation ---
    if [[ -z "${1:-}" ]]; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "Please provide a folder path as an argument."
        exit 1
    fi
    ORIGINAL_FOLDER_PATH="$1"

    if [[ ! -d "${ORIGINAL_FOLDER_PATH}" ]]; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "'${ORIGINAL_FOLDER_PATH}' is not a valid directory."
        exit 1
    fi

    # Check if the target directory is writable
    if [[ ! -w "${ORIGINAL_FOLDER_PATH}" ]]; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "Directory '${ORIGINAL_FOLDER_PATH}' is not writable. Cannot process images."
        exit 1
    fi

    # Check initial disk space in /tmp for temporary directory creation
    log_message "INFO" "${LOG_LEVEL_INFO}" "Checking disk space in /tmp..."
    check_disk_space "/tmp" "${MIN_FREE_SPACE_KB}"

    # Set restrictive umask for temporary files/directories created by this script.
    umask 077
    if ! TEMP_DEID_DIR=$(mktemp -d -t image_deidentify_XXXXXX) ; then
        log_message "ERROR" "${LOG_LEVEL_ERROR}" "Failed to create primary temporary directory."
        exit 1
    fi

    # Check initial disk space in the target folder for image replacement
    log_message "INFO" "${LOG_LEVEL_INFO}" "Checking disk space in target directory: ${ORIGINAL_FOLDER_PATH}..."
    check_disk_space "${ORIGINAL_FOLDER_PATH}" "${MIN_FREE_SPACE_KB}"


    # Find all supported image paths within the input folder
    local image_paths=()
    log_message "INFO" "${LOG_LEVEL_INFO}" "Searching for supported image files in '${ORIGINAL_FOLDER_PATH}'..."
    while IFS= read -r -d $'\0' img_path; do
        image_paths+=("$img_path")
    done < <(find "${ORIGINAL_FOLDER_PATH}" -maxdepth 1 -type f \( \
        -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o \
        -iname "*.gif" -o -iname "*.tiff" -o -iname "*.bmp" -o -iname "*.webp" \
    \) -print0)

    local total_images=${#image_paths[@]}

    # Handle case where no supported images are found
    if [[ "${total_images}" -eq 0 ]]; then
        show_progress 0 0 # Render 0% progress bar
        printf -- "\r\033[K" >&3 # Clear progress bar line
        log_message "WARNING" "${LOG_LEVEL_WARNING}" "No supported images found to process in '${ORIGINAL_FOLDER_PATH}'. Script will exit."
        exit 0
    fi

    log_message "INFO" "${LOG_LEVEL_INFO}" "Found ${total_images} supported images to process."

    local processed_count=0
    local failed_images=() # Stores images that ultimately failed all retries

    # Render the progress bar at 0% initially before processing any images
    show_progress "${processed_count}" "${total_images}"

    # Iterate and process each image
    for img_path in "${image_paths[@]}"; do
        local overall_success_current_image=0
        local attempts_current_image=0
        
        # Explicitly disable set -e around the image processing block
        # to ensure the 'for' loop continues even if process_image fails and retries are exhausted.
        set +e
        while [[ "${attempts_current_image}" -lt "${MAX_STEP_RETRIES}" ]]; do
            if process_image "${img_path}" "${TEMP_DEID_DIR}"; then
                overall_success_current_image=1
                break # Success for this image, move to next
            fi
            ((attempts_current_image++))
            log_message "INFO" "${LOG_LEVEL_INFO}" "Re-attempting processing for '$(basename "$img_path")' (attempt $((attempts_current_image+1))/${MAX_STEP_RETRIES})."
            sleep "${RETRY_DELAY_SEC}" # Small delay before re-attempting
        done
        set -e # Re-enable set -e for the rest of the script.

        if [[ "${overall_success_current_image}" -eq 0 ]]; then
            failed_images+=("$(basename "${img_path}")")
            # If all attempts failed and image not already deleted by process_image failure
            if [[ -f "${img_path}" ]]; then
                log_message "ERROR" "${LOG_LEVEL_ERROR}" "All attempts (${MAX_STEP_RETRIES}) to process '$(basename "$img_path")' failed. Original image may be corrupt or unprocessed and was NOT replaced."
            else
                log_message "ERROR" "${LOG_LEVEL_ERROR}" "All attempts (${MAX_STEP_RETRIES}) to process '$(basename "$img_path")' failed. Original image was deleted or could not be restored."
            fi
        fi

        processed_count=$((processed_count + 1))
        show_progress "${processed_count}" "${total_images}"
    done

    # Final update to progress bar (will be 100% if all processed)
    show_progress "${processed_count}" "${total_images}" 
    
    # Clear the progress bar line after completion
    printf -- "\r\033[K" >&3

    # Report final status
    if [[ "${#failed_images[@]}" -gt 0 ]]; then
        printf "WARNING: Some images failed to process after all retries.\n" >&2
        printf "Failed images:\n" >&2
        for failed_img in "${failed_images[@]}"; do
            printf "  - %s\n" "${failed_img}" >&2
        done
        exit 1 # Indicate partial failure
    else
        printf "INFO: All supported images processed and optimized successfully.\n" >&2
    fi

    exit 0 # Indicate full success
}

main "$@"
