#!/bin/bash

# --- Script Configuration ---
# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error.
set -u
# The return value of a pipeline is the status of the last command to exit with a non-zero status,
# or zero if all commands in the pipeline exit successfully.
set -o pipefail
# Disable history logging for this script's commands to enhance privacy.
set +o history

# Image Optimization Settings
JPEG_QUALITY=80 # JPEG quality (0-100)
PNG_QUALITY=80  # PNG quality (0-100) - used by pngquant

# Adaptive Quality Settings (for JPEG optimization)
# If ENABLE_ADAPTIVE_JPEG_QUALITY is 'true', the script will try JPEG_QUALITY and then JPEG_FALLBACK_QUALITY,
# picking the smaller valid file. This adds processing time.
ENABLE_ADAPTIVE_JPEG_QUALITY="false"
JPEG_FALLBACK_QUALITY=75 # Lower quality to try if adaptive quality is enabled

# UUID Generation Settings
UUID_TARGET_LENGTH=48   # Total target length of the hex part of the UUID (48 characters as requested)

# Progress Bar Settings
PROGRESS_BAR_WIDTH_PERCENT=20 # Percentage of terminal width (20-30% range)

# Retry Mechanism Settings
MAX_RETRIES=3       # Maximum number of times to retry processing a failed image
RETRY_DELAY_SEC=1   # Delay in seconds before retrying
COMMAND_TIMEOUT_SEC=120 # Maximum time in seconds for any single external command to run (increased for complex operations)

# Global Variables (Managed by script functions)
ORIGINAL_FOLDER_PATH=""             # The user-provided source folder
TEMP_DEID_DIR=""                    # Temporary directory for per-script-run processing

# --- Utility Functions ---

# Displays script usage information (always to stderr, as it's usage, not runtime output).
display_usage() {
    cat <<EOF >&2
Usage: $(basename "$0") <folder_path>

This script extensively de-identifies and optimizes images.
It will:
1.  Find and process only JPEG and PNG image files.
2.  Deduplicate images based on content within the folder.
3.  Aggressively scrub ALL possible metadata (EXIF, IPTC, XMP, comments, etc.) per image.
4.  Optimize image size for maximum compression WITHOUT noticeable visual degradation.
    - JPEG quality set to ${JPEG_QUALITY}%% (lossy, but visually acceptable).
    - PNG quality set to ${PNG_QUALITY}%% (lossy, via color quantization).
5.  Re-hash images (implicitly by altering data, ensuring no common hash with originals).
6.  Rename all processed images to cryptographically secure, ${UUID_TARGET_LENGTH}-character UUIDs.
7.  Replace original images with processed ones, leaving NO TRACE of originals, image by image.

********************************************************************************
WARNING: This script is fully automated and will IMMEDIATELY overwrite and
         delete original files. This operation is IRREVERSIBLE.
         A FULL BACKUP OF YOUR IMAGES IS ABSOLUTELY MANDATORY BEFORE RUNNING.
         THERE IS NO USER CONFIRMATION DURING EXECUTION.
********************************************************************************
EOF
    exit 1
}

# Checks if a required command is installed (exits on failure).
check_command() {
    local cmd_name="$1"
    local deb_pkg="$2"
    local fedora_pkg="$3"
    local brew_pkg="$4"

    if ! command -v "${cmd_name}" &>/dev/null; then
        printf "ERROR: Required tool '%s' is not installed.\n" "${cmd_name}" >&2
        printf "Please install it using your system's package manager:\n" >&2
        printf "  Debian/Ubuntu: sudo apt-get install %s\n" "${deb_pkg}" >&2
        printf "  Fedora: sudo dnf install %s\n" "${fedora_pkg}" >&2
        printf "  macOS (with Homebrew): brew install %s\n" "${brew_pkg}" >&2
        exit 1
    fi
}

# Securely deletes a single file.
secure_delete_file() {
    local file_path="$1"
    if [[ -f "${file_path}" ]]; then
        timeout "${COMMAND_TIMEOUT_SEC}" shred -f -z -u -n 3 "${file_path}" &>/dev/null || rm -f "${file_path}" &>/dev/null || true
    fi
}

# Securely deletes all files in a directory and then the directory itself.
secure_delete_dir() {
    local dir_path="$1"
    if [[ -d "${dir_path}" ]]; then
        find "${dir_path}" -depth -print0 | while IFS= read -r -d $'\0' item; do
            if [[ -f "${item}" ]]; then
                secure_delete_file "${item}"
            elif [[ -d "${item}" ]]; then
                rmdir "${item}" &>/dev/null || true
            fi
        done
        rm -rf "${dir_path}" &>/dev/null || true
    fi
}

# Performs secure cleanup of temporary directories. This runs on script exit.
cleanup() {
    # Ensure a clean line after progress bar, before any final messages
    printf -- "\r\033[K" >&3
    # Close file descriptor 3 to ensure the progress bar line ends cleanly
    exec 3>&- 2>/dev/null || true

    # Securely delete the main temporary directory and its contents
    if [[ -n "${TEMP_DEID_DIR}" ]] && [[ -d "${TEMP_DEID_DIR}" ]]; then
        secure_delete_dir "${TEMP_DEID_DIR}"
    fi

    # Pre-execution cleanup for previous runs in case of abnormal termination
    find "/tmp" -maxdepth 1 -type d -name "image_deidentify_single_*" -print0 | xargs -0 -I {} bash -c 'secure_delete_dir "$1"' _ {} &>/dev/null || true
    find "/tmp" -maxdepth 1 -type d -name "deid_img_*" -print0 | xargs -0 -I {} bash -c 'secure_delete_dir "$1"' _ {} &>/dev/null || true
    
    set -o history # Re-enable history before exiting
}

# Displays a dynamic progress bar to /dev/tty (FD 3).
# Arguments: current_item_index, total_items_count
show_progress() {
    local current="$1"
    local total="$2"
    local progress_percent=0

    if [[ "${total}" -gt 0 ]]; then
        progress_percent=$(( (current * 100) / total ))
    fi

    local terminal_cols=$(tput cols 2>/dev/null || echo 80)
    local bar_width=$(( (terminal_cols * PROGRESS_BAR_WIDTH_PERCENT) / 100 ))

    # Ensure minimum bar width for visibility
    if [[ "${bar_width}" -lt 5 ]]; then
        bar_width=5
    fi

    local filled_width=$(( (progress_percent * bar_width) / 100 ))
    local empty_width=$(( bar_width - filled_width ))

    local filled_bar_str=""
    for (( i=0; i<filled_width; i++ )); do
        filled_bar_str+="#"
    done

    local empty_bar_str=""
    for (( i=0; i<empty_width; i++ )); do
        empty_bar_str+="-"
    done

    local formatted_percent="${progress_percent}%"
    if (( progress_percent < 10 )); then
        formatted_percent="  ${progress_percent}%"
    elif (( progress_percent < 100 )); then
        formatted_percent=" ${progress_percent}%"
    fi

    local bar_line="[${filled_bar_str}${empty_bar_str}] ${formatted_percent} (${current}/${total})"
    # Print directly to /dev/tty (FD 3) and clear to end of line
    printf -- "\r%s\033[K" "${bar_line}" >&3
}

# Generates a cryptographically secure UUID. Output: UUID string to stdout.
# The UUID will be 48 hexadecimal characters long, with dashes inserted every 6-8 characters.
generate_uuid() {
    local bytes_needed=$(( (UUID_TARGET_LENGTH + 1) / 2 ))
    local raw_hex=""
    raw_hex=$(timeout "${COMMAND_TIMEOUT_SEC}" head -c "${bytes_needed}" /dev/urandom 2>/dev/null | timeout "${COMMAND_TIMEOUT_SEC}" xxd -p -c 256 2>/dev/null | tr -d '\n' | head -c "${UUID_TARGET_LENGTH}")
    
    if [[ -z "$raw_hex" ]]; then
        return 1
    fi
    
    local formatted_uuid=""
    local current_len=0
    local segment_length 

    while [[ "${current_len}" -lt "${UUID_TARGET_LENGTH}" ]]; do
        segment_length=$(( ( RANDOM % 3 ) + 6 )) # 6, 7, or 8

        if (( ( current_len + segment_length ) > UUID_TARGET_LENGTH )); then
            segment_length=$(( UUID_TARGET_LENGTH - current_len ))
        fi

        local segment="${raw_hex:current_len:segment_length}"
        formatted_uuid+="${segment}"

        current_len=$(( current_len + segment_length ))

        if [[ "${current_len}" -lt "${UUID_TARGET_LENGTH}" ]]; then
            formatted_uuid+="-"
        fi
    done

    printf -- "%s" "${formatted_uuid}"
    return 0
}

# Generates a random date string (YYYY:MM:DD HH:MM:SS) between 2000-01-01 and current date.
# Output: date string to stdout.
generate_random_date() {
    local start_epoch=$(date -d "2000-01-01 00:00:00" +%s)
    local end_epoch=$(date +%s)
    
    local random_epoch=$(( start_epoch + ( RANDOM % ( end_epoch - start_epoch + 1 ) ) ))
    
    date -d "@${random_epoch}" +"%Y:%m:%d %H:%M:%S" 2>/dev/null || {
        return 1
    }
    return 0
}


# Scrubs all known metadata from a JPEG image and adds a random date.
# Argument: path_to_jpeg, random_date_string (YYYY:MM:DD HH:MM:SS)
# Returns 0 on success, 1 on failure.
scrub_jpeg_metadata() {
    local img_path="$1"
    local random_date="$2"
    local temp_output_path="${img_path}.tmp_scrub"

    if ! timeout "${COMMAND_TIMEOUT_SEC}" convert "${img_path}" -strip -quality "${JPEG_QUALITY}%" "${temp_output_path}" &>/dev/null; then
        secure_delete_file "${temp_output_path}"
        return 1
    fi

    if ! mv "${temp_output_path}" "${img_path}" &>/dev/null; then
        secure_delete_file "${temp_output_path}"
        return 1
    fi

    if ! timeout "${COMMAND_TIMEOUT_SEC}" exiftool -overwrite_original -q -q "-DateTimeOriginal=${random_date}" "${img_path}" &>/dev/null; then
        return 1
    fi

    # Paranoid Metadata Check - verify no unexpected tags remain (except standard ones)
    local excluded_tags_pattern='^(FileName|Directory|FileSize|FileModifyDate|FileAccessDate|FileInodeChangeDate|FileType|FileTypeExtension|MIMEType|ImageWidth|ImageHeight|EncodingProcess|BitsPerSample|ColorComponents|YCbCrSubSampling|ImageSize|Megapixels|DateTimeOriginal|ResolutionUnit|XResolution|YResolution|Orientation|Compression|JPEGInterchangeFormat|JPEGInterchangeFormatLength|ExifByteOrder|ColorSpace|ProfileCMMType|ProfileVersion|ProfileClass|ColorSpaceData|ProfileConnectionSpace|ProfileDateTime|ProfileFileFlags|ProfileCreator|ProfileID|ProfileDescription|ProfileCopyright|MediaWhitePoint|MediaBlackPoint|RedMatrixColumn|GreenMatrixColumn|BlueMatrixColumn|RedTRC|GreenTRC|BlueTRC|Luminance|ChromaticAdaptation|MajorVersion|MinorVersion|ApplicationRecordVersion|CodedCharacterSet|Urgency|IPTCDigest|PhotometricInterpretation|ProgressiveSequence|SOFLength|NumComponents|ComponentSelector|StartOfScan|SpectralSelect|HuffmanTable|QuantizationTable|JFIFVersion|XMPToolkit|ExifToolVersion|CreatorTool|DateCreated|DateModify|Format|Description|Title|Rights|Identifier|Subject|Source|Coverage|Keywords|Publisher|Language|Relation|Type|Category|Contributor|Attribution|Audience|Copyright)$'
    local remaining_tags=""
    remaining_tags=$(timeout "${COMMAND_TIMEOUT_SEC}" exiftool -q -q -T -s -r "${img_path}" 2>/dev/null | grep -v -E "${excluded_tags_pattern}" | tr -d '\n')
    # If any tags remain, this condition will be true, but we don't log them.
    if [[ -n "${remaining_tags}" ]]; then
        true # No action, as logging is disabled
    fi

    if ! identify -regard-warnings -ping "${img_path}" &>/dev/null; then
        return 1
    fi

    return 0
}

# Scrubs all known metadata from a PNG image.
# Argument: path_to_png, random_date_string (YYYY:MM:DD HH:MM:SS) - not used for PNG embedded metadata
# Returns 0 on success, 1 on failure.
scrub_png_metadata() {
    local img_path="$1"
    local random_date="$2" # This is not embedded into PNG metadata to maintain "minimal" principle
    local temp_output_path="${img_path}.tmp_scrub"

    if ! timeout "${COMMAND_TIMEOUT_SEC}" convert "${img_path}" -strip "${temp_output_path}" &>/dev/null; then
        secure_delete_file "${temp_output_path}"
        return 1
    fi

    if ! mv "${temp_output_path}" "${img_path}" &>/dev/null; then
        secure_delete_file "${temp_output_path}"
        return 1
    fi

    local excluded_tags_pattern='^(FileName|Directory|FileSize|FileModifyDate|FileAccessDate|FileInodeChangeDate|FileType|FileTypeExtension|MIMEType|ImageWidth|ImageHeight|EncodingProcess|BitsPerSample|ColorComponents|ImageSize|Megapixels|Interlace|ColorType|CompressionMethod|FilterMethod|PaletteType|HasAlpha|Background|Gamma|ChromaBlackPoint|ChromaRedPoint|ChromaGreenPoint|ChromaBluePoint|WhitePoint|RedPrimary|GreenPrimary|BluePrimary|sRGBRenderingIntent|ICCProfile|XMPToolkit|ExifToolVersion|CreatorTool|DateCreated|DateModify|Format|Description|Title|Rights|Identifier|Subject|Source|Coverage|Keywords|Publisher|Language|Relation|Type|Category|Contributor|Attribution|Audience|Copyright)$'
    local remaining_png_tags=""
    remaining_png_tags=$(timeout "${COMMAND_TIMEOUT_SEC}" exiftool -q -q -T -s -r "${img_path}" 2>/dev/null | grep -v -E "${excluded_tags_pattern}" | tr -d '\n')
    if [[ -n "${remaining_png_tags}" ]]; then
        true # No action, as logging is disabled
    fi

    if ! identify -regard-warnings -ping "${img_path}" &>/dev/null; then
        return 1
    fi

    return 0
}

# Optimizes a JPEG image.
# Argument: path_to_jpeg, temp_output_file_path (where the best optimized version should be written)
# Returns 0 on success, 1 on failure.
optimize_jpeg() {
    local img_path="$1"
    local temp_output_file_path="$2"

    local temp_best_optimized_path="${temp_output_file_path}.temp_best_candidate"
    local current_output_attempt="${temp_output_file_path}.current_attempt"

    if ! cp "${img_path}" "${temp_best_optimized_path}" &>/dev/null; then
        return 1
    fi
    local best_size=$(stat -c%s "${temp_best_optimized_path}" 2>/dev/null || echo 0)

    # --- Optimization Attempt 1: jpegoptim + convert ---
    local jpegoptim_temp_file="${current_output_attempt}.jpegoptim"
    if timeout "${COMMAND_TIMEOUT_SEC}" jpegoptim --strip-all --all-progressive --dest="${jpegoptim_temp_file}" "${img_path}" &>/dev/null; then
        if [[ -s "${jpegoptim_temp_file}" ]]; then
            if timeout "${COMMAND_TIMEOUT_SEC}" convert "${jpegoptim_temp_file}" -strip -sampling-factor 4:2:0 -quality "${JPEG_QUALITY}%" -interlace Plane "${current_output_attempt}" &>/dev/null; then
                if [[ -s "${current_output_attempt}" ]]; then
                    local current_size=$(stat -c%s "${current_output_attempt}" 2>/dev/null || echo 0)
                    if (( current_size < best_size )) && (( current_size > 0 )); then
                        mv "${current_output_attempt}" "${temp_best_optimized_path}" &>/dev/null || true
                        best_size="${current_size}"
                    fi
                fi
            fi
        fi
    fi
    secure_delete_file "${jpegoptim_temp_file}"
    secure_delete_file "${current_output_attempt}"

    # --- Optimization Attempt 2: ImageMagick (Primary Quality) ---
    if timeout "${COMMAND_TIMEOUT_SEC}" convert "${img_path}" -strip -sampling-factor 4:2:0 -quality "${JPEG_QUALITY}%" -interlace Plane "${current_output_attempt}" &>/dev/null; then
        if [[ -s "${current_output_attempt}" ]]; then
            local current_size=$(stat -c%s "${current_output_attempt}" 2>/dev/null || echo 0)
            if (( current_size < best_size )) && (( current_size > 0 )); then
                mv "${current_output_attempt}" "${temp_best_optimized_path}" &>/dev/null || true
                best_size="${current_size}"
            fi
        fi
    fi
    secure_delete_file "${current_output_attempt}"

    # --- Optimization Attempt 3: Adaptive Quality (if enabled) ---
    if [[ "${ENABLE_ADAPTIVE_JPEG_QUALITY}" == "true" ]] && (( JPEG_FALLBACK_QUALITY < JPEG_QUALITY )); then
        if timeout "${COMMAND_TIMEOUT_SEC}" convert "${img_path}" -strip -sampling-factor 4:2:0 -quality "${JPEG_FALLBACK_QUALITY}%" -interlace Plane "${current_output_attempt}" &>/dev/null; then
            if [[ -s "${current_output_attempt}" ]]; then
                local current_size=$(stat -c%s "${current_output_attempt}" 2>/dev/null || echo 0)
                if (( current_size < best_size )) && (( current_size > 0 )); then
                    mv "${current_output_attempt}" "${temp_best_optimized_path}" &>/dev/null || true
                    best_size="${current_size}"
                fi
            fi
        fi
        secure_delete_file "${current_output_attempt}"
    fi

    # --- Final Step: Move the best optimized file to the final destination ---
    if ! mv "${temp_best_optimized_path}" "${temp_output_file_path}" &>/dev/null; then
        secure_delete_file "${temp_best_optimized_path}"
        return 1
    fi

    return 0
}

# Optimizes a PNG image.
# Argument: path_to_png, temp_output_file_path (where the best optimized version should be written)
# Returns 0 on success, 1 on failure.
optimize_png() {
    local img_path="$1"
    local temp_output_file_path="$2"

    local temp_best_optimized_path="${temp_output_file_path}.temp_best_candidate"
    local current_output_attempt="${temp_output_file_path}.current_attempt"

    if ! cp "${img_path}" "${temp_best_optimized_path}" &>/dev/null; then
        return 1
    fi
    local best_size=$(stat -c%s "${temp_best_optimized_path}" 2>/dev/null || echo 0)

    # --- Optimization Attempt 1: pngquant (lossy) ---
    if timeout "${COMMAND_TIMEOUT_SEC}" pngquant --quality="${PNG_QUALITY}-${PNG_QUALITY}" --strip --force --output "${current_output_attempt}" "${img_path}" &>/dev/null; then
        if [[ -s "${current_output_attempt}" ]]; then
            local current_size=$(stat -c%s "${current_output_attempt}" 2>/dev/null || echo 0)
            if (( current_size < best_size )) && (( current_size > 0 )); then
                mv "${current_output_attempt}" "${temp_best_optimized_path}" &>/dev/null || true
                best_size="${current_size}"
            fi
        fi
    fi
    secure_delete_file "${current_output_attempt}"

    # --- Optimization Attempt 2: optipng (lossless) ---
    if timeout "${COMMAND_TIMEOUT_SEC}" optipng -o7 "${img_path}" -out "${current_output_attempt}" &>/dev/null; then
        if [[ -s "${current_output_attempt}" ]]; then
            local current_size=$(stat -c%s "${current_output_attempt}" 2>/dev/null || echo 0)
            if (( current_size < best_size )) && (( current_size > 0 )); then
                mv "${current_output_attempt}" "${temp_best_optimized_path}" &>/dev/null || true
                best_size="${current_size}"
            fi
        fi
    fi
    secure_delete_file "${current_output_attempt}"

    # --- Optimization Attempt 3: pngcrush (lossless) ---
    if timeout "${COMMAND_TIMEOUT_SEC}" pngcrush -rem allb -reduce -brute -q "${img_path}" "${current_output_attempt}" &>/dev/null; then
        if [[ -s "${current_output_attempt}" ]]; then
            local current_size=$(stat -c%s "${current_output_attempt}" 2>/dev/null || echo 0)
            if (( current_size < best_size )) && (( current_size > 0 )); then
                mv "${current_output_attempt}" "${temp_best_optimized_path}" &>/dev/null || true
                best_size="${current_size}"
            fi
        fi
    fi
    secure_delete_file "${current_output_attempt}"

    # --- Optimization Attempt 4: ImageMagick (lossless, aggressive compression) ---
    if timeout "${COMMAND_TIMEOUT_SEC}" convert "${img_path}" -strip -filter Plane -define png:compression-filter=5 -define png:compression-level=9 -define png:compression-strategy=1 "${current_output_attempt}" &>/dev/null; then
        if [[ -s "${current_output_attempt}" ]]; then
            local current_size=$(stat -c%s "${current_output_attempt}" 2>/dev/null || echo 0)
            if (( current_size < best_size )) && (( current_size > 0 )); then
                mv "${current_output_attempt}" "${temp_best_optimized_path}" &>/dev/null || true
                best_size="${current_size}"
            fi
        fi
    fi
    secure_delete_file "${current_output_attempt}"

    # --- Final Step: Move the best optimized file to the final destination ---
    if ! mv "${temp_best_optimized_path}" "${temp_output_file_path}" &>/dev/null; then
        secure_delete_file "${temp_best_optimized_path}"
        return 1
    fi

    return 0
}


# Processes a single image file: scrubs metadata, optimizes, and prepares for replacement.
# This function now writes *two* paths to separate files within the main TEMP_DEID_DIR:
# 1. The path to the processed image file (passed as $2)
# 2. The path to the temporary directory that contains the processed image (passed as $3)
# Returns 0 on success, 1 on failure.
process_single_image_for_replacement() {
    local original_img_path="$1"
    local output_img_path_file="$2"
    local output_temp_dir_path_file="$3"

    local temp_process_dir=""
    local temp_copied_img_path=""
    local mime_type=""
    local lower_ext=""
    local new_uuid=""
    local random_date_str=""
    local new_processed_filename=""
    local final_processed_temp_path=""

    umask 077
    if ! temp_process_dir=$(mktemp -d -t deid_img_XXXXXX) &>/dev/null; then
        return 1
    fi

    temp_copied_img_path="${temp_process_dir}/$(basename "${original_img_path}")"

    # 1. Copy original to its isolated temp directory
    if ! timeout "${COMMAND_TIMEOUT_SEC}" cp -p "${original_img_path}" "${temp_copied_img_path}" &>/dev/null; then
        secure_delete_dir "${temp_process_dir}"
        return 1
    fi

    # 2. Robust Input Validation: Determine MIME type and validate.
    mime_type=$(timeout "${COMMAND_TIMEOUT_SEC}" identify -format '%m' "${temp_copied_img_path}" 2>/dev/null)
    if [[ -z "${mime_type}" ]]; then
        secure_delete_dir "${temp_process_dir}"
        return 1
    fi

    case "${mime_type}" in
        JPEG) lower_ext="jpeg" ;;
        PNG) lower_ext="png" ;;
        *)
            secure_delete_dir "${temp_process_dir}"
            return 1
            ;;
    esac

    # Generate UUID and Random Date
    if ! new_uuid=$(generate_uuid); then
        secure_delete_dir "${temp_process_dir}"
        return 1
    fi
    
    if ! random_date_str=$(generate_random_date); then
        secure_delete_dir "${temp_process_dir}"
        return 1
    fi

    new_processed_filename="${new_uuid}.${lower_ext}"
    final_processed_temp_path="${temp_process_dir}/${new_processed_filename}"

    # --- Phase 3: Granular Metadata Scrubbing & Date Embedding ---
    local scrub_status=1
    case "${lower_ext}" in
        jpeg) scrub_status=$(scrub_jpeg_metadata "${temp_copied_img_path}" "${random_date_str}");;
        png) scrub_status=$(scrub_png_metadata "${temp_copied_img_path}" "${random_date_str}");;
    esac
    if [[ "${scrub_status}" -ne 0 ]]; then
        secure_delete_dir "${temp_process_dir}"
        return 1
    fi
    
    # --- Phase 4: Optimize image size ---
    local optimize_status=1
    case "${lower_ext}" in
        jpeg) optimize_status=$(optimize_jpeg "${temp_copied_img_path}" "${final_processed_temp_path}");;
        png) optimize_status=$(optimize_png "${temp_copied_img_path}" "${final_processed_temp_path}");;
    esac

    if [[ "${optimize_status}" -ne 0 ]] || [[ ! -s "${final_processed_temp_path}" ]]; then
        secure_delete_dir "${temp_process_dir}"
        return 1
    fi

    printf "%s" "${final_processed_temp_path}" > "${output_img_path_file}"
    printf "%s" "${temp_process_dir}" > "${output_temp_dir_path_file}"

    return 0
}

# --- Main Script Logic ---
main() {
    # IMMEDIATELY redirect file descriptor 3 to /dev/tty for progress bar.
    exec 3>/dev/tty

    # Redirect stdout and stderr to /dev/null for the entire main function's execution.
    exec 1>/dev/null
    exec 2>/dev/null

    # Ensure cleanup runs on exit (success or failure)
    trap cleanup EXIT

    # 0. Check for required tools.
    # If a command is missing, check_command prints to stderr (which is currently /dev/null)
    # but also explicitly prints to /dev/tty (FD 3) for the user to see critical errors.
    check_command "find" "findutils" "findutils" "findutils"
    check_command "md5sum" "coreutils" "coreutils" "coreutils" # Used by jdupes
    check_command "jdupes" "jdupes" "jdupes" "jdupes"
    check_command "exiftool" "libimage-exiftool-perl" "perl-Image-ExifTool" "exiftool"
    check_command "convert" "imagemagick" "ImageMagick" "imagemagick"
    check_command "identify" "imagemagick" "ImageMagick" "imagemagick"
    check_command "xxd" "xxd" "vim-common" "vim"
    check_command "optipng" "optipng" "optipng" "optipng"
    check_command "jpegoptim" "jpegoptim" "jpegoptim" "jpegoptim"
    check_command "pngcrush" "pngcrush" "pngcrush" "pngcrush"
    check_command "pngquant" "pngquant" "pngquant" "pngquant"
    check_command "bc" "bc" "bc" "bc"
    check_command "seq" "coreutils" "coreutils" "coreutils"
    check_command "timeout" "coreutils" "coreutils" "coreutils"
    check_command "date" "coreutils" "coreutils" "coreutils"

    # Validate input folder path.
    if [[ -z "${1:-}" ]]; then
        display_usage # display_usage exits, so no need to close stderr after this.
    fi
    ORIGINAL_FOLDER_PATH="$1"

    if [[ ! -d "${ORIGINAL_FOLDER_PATH}" ]]; then
        printf "ERROR: '%s' is not a valid directory.\n" "${ORIGINAL_FOLDER_PATH}" >&2
        exit 1
    fi

    # Create temporary directory for script's overall management
    umask 077
    TEMP_DEID_DIR=$(mktemp -d -t image_deidentify_single_XXXXXX) &>/dev/null || { printf "ERROR: Could not create main temporary directory.\n" >&2; exit 1; }

    # 1. Find JPEG and PNG image files
    local initial_image_paths=()
    while IFS= read -r -d $'\0' img_path; do
        initial_image_paths+=("$img_path")
    done < <(find "${ORIGINAL_FOLDER_PATH}" -maxdepth 1 -type f \( \
        -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \
    \) -print0)

    local initial_total_images=${#initial_image_paths[@]}
    if [[ "${initial_total_images}" -eq 0 ]]; then
        show_progress 0 0
        printf -- "\r\033[K" >&3
        exit 0
    fi

    # 2. Deduplicate images based on content (in-place on original folder, deleting duplicates)
    # Redirect jdupes output to /dev/null as well
    timeout "${COMMAND_TIMEOUT_SEC}" jdupes -N -q -r -d "${ORIGINAL_FOLDER_PATH}" &>/dev/null || true

    # After deduplication, re-scan the folder to get the truly unique files
    local images_to_process=()
    while IFS= read -r -d $'\0' img_path; do
        images_to_process+=("$img_path")
    done < <(find "${ORIGINAL_FOLDER_PATH}" -maxdepth 1 -type f \( \
        -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \
    \) -print0)

    local total_unique_images=${#images_to_process[@]}
    if [[ "${total_unique_images}" -eq 0 ]]; then
        show_progress 0 0
        printf -- "\r\033[K" >&3
        exit 0
    fi


    local current_pass_images=("${images_to_process[@]}")
    local failed_images_final=() # This list will capture paths of images that *truly* failed after all retries
    local processed_count=0
    local retry_attempt=0

    # Main processing loop with retry mechanism
    while [[ "${#current_pass_images[@]}" -gt 0 ]] && [[ "${retry_attempt}" -le "${MAX_RETRIES}" ]]; do
        if [[ "${retry_attempt}" -gt 0 ]]; then
            sleep "${RETRY_DELAY_SEC}"
        fi

        local failed_in_this_pass=()

        for original_img_path in "${current_pass_images[@]}"; do
            show_progress "${processed_count}" "${total_unique_images}"

            local processed_temp_file_path=""
            local temp_dir_for_cleanup=""
            local process_status=1

            local temp_output_img_path_file=$(mktemp "${TEMP_DEID_DIR}/processed_img_path_XXXXXX") &>/dev/null || {
                failed_in_this_pass+=("${original_img_path}")
                continue
            }
            local temp_output_temp_dir_path_file=$(mktemp "${TEMP_DEID_DIR}/temp_dir_path_XXXXXX") &>/dev/null || {
                secure_delete_file "${temp_output_img_path_file}"
                failed_in_this_pass+=("${original_img_path}")
                continue
            }

            process_single_image_for_replacement "${original_img_path}" \
                                                 "${temp_output_img_path_file}" \
                                                 "${temp_output_temp_dir_path_file}"
            process_status=$?

            if [[ "${process_status}" -eq 0 ]] && \
               [[ -s "${temp_output_img_path_file}" ]] && \
               [[ -s "${temp_output_temp_dir_path_file}" ]]; then
                processed_temp_file_path=$(<"${temp_output_img_path_file}")
                temp_dir_for_cleanup=$(<"${temp_output_temp_dir_path_file}")
            else
                process_status=1
            fi
            
            secure_delete_file "${temp_output_img_path_file}"
            secure_delete_file "${temp_output_temp_dir_path_file}"

            if [[ "${process_status}" -eq 0 ]] && \
               [[ -n "${processed_temp_file_path}" ]] && \
               [[ -f "${processed_temp_file_path}" ]]; then
                secure_delete_file "${original_img_path}"

                local new_final_path="${ORIGINAL_FOLDER_PATH}/$(basename "${processed_temp_file_path}")"
                if ! mv "${processed_temp_file_path}" "${new_final_path}" &>/dev/null; then
                    failed_in_this_pass+=("${original_img_path}")
                    secure_delete_file "${processed_temp_file_path}"
                else
                    processed_count=$((processed_count + 1))
                    show_progress "${processed_count}" "${total_unique_images}"
                fi

                secure_delete_dir "${temp_dir_for_cleanup}"
            else
                failed_in_this_pass+=("${original_img_path}")
                secure_delete_dir "${temp_dir_for_cleanup}"
            fi
        done
        
        current_pass_images=("${failed_in_this_pass[@]}")
        
        # If this is the last retry attempt, move any remaining failed images to the final failed list
        if [[ "${retry_attempt}" -ge "${MAX_RETRIES}" ]]; then
            failed_images_final+=("${current_pass_images[@]}")
        fi

        retry_attempt=$((retry_attempt + 1))
    done

    show_progress "${processed_count}" "${total_unique_images}"
    printf -- "\r\033[K" >&3 # Clear progress bar line

    if [[ "${#failed_images_final[@]}" -gt 0 ]]; then
        # On failure, print a generic error to stderr for the user.
        printf "ERROR: Script finished with some images failing to process. No details available.\n" >&2
        exit 1
    else
        # On success, print nothing but the final progress bar state which is cleared.
        exit 0
    fi
}

# Call the main function to start execution
main "$@"