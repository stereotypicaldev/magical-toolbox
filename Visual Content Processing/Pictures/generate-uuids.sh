#!/bin/bash

# This script renames image files and tracks progress,
# ensuring a graceful shutdown even when interrupted.

# ==============================================================================
# 1. Security and Robustness Settings
# ==============================================================================
set -euo pipefail

# ==============================================================================
# 2. Configuration Variables
# ==============================================================================
# Supported image extensions (add or remove as needed). Case-insensitive matching later.
declare -ar IMAGE_EXTENSIONS=("jpg" "jpeg" "png" "gif" "bmp" "tiff" "webp")

# Desired total length of the raw hexadecimal string for the generated UUIDs.
# The pattern {6}-{8}-{8}-{8}-{8}-{6}-{4} sums to 6+8+8+8+8+6+4 = 48 characters.
# This fixed length ensures visual uniformity when displayed with a monospace font.
readonly UUID_RAW_LENGTH=48

# Retry settings for file operations (e.g., if target is on a flaky network share or temporary lock)
readonly MAX_RETRIES=3
readonly RETRY_DELAY_SECONDS=1 # Seconds to wait between retry attempts

# Folder path variable (will be set by argument parsing)
folder_path=""

# Variable to track the temporary file used for write permission testing.
# Declared globally so the 'cleanup' trap can access it reliably.
TEMP_WRITE_TEST_FILE=""

# --- FIFO & Background Process Management ---
# Path for the Inter-Process Communication (IPC) FIFO (Named Pipe).
# This is how the main script communicates progress to the background counter reader.
readonly FIFO_PATH="/tmp/rename_progress_fifo"
# Variable to store the Process ID (PID) of the background counter reader.
# This allows the main script to manage its lifecycle.
COUNTER_READER_PID=""

# Counters for internal tracking (not displayed in the progress bar anymore)
RENAMED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

# Progress bar variables
TOTAL_FILES=0       # Total image files identified for processing.
PROCESSED_FILES=0   # Files for which processing was attempted (renamed, skipped, or failed).
HAS_TERMINAL=false  # Flag to check if stdout is a terminal, to enable progress bar.

# ==============================================================================
# 3. Functions
# ==============================================================================

# cleanup:
# This function is executed automatically when the script exits (due to 'trap EXIT').
# Its primary purpose is to ensure any temporary files created by the script are removed,
# and to gracefully terminate any background processes launched by the script.
cleanup() {
    # Ensure a final newline for the progress bar display if stdout was a terminal.
    if "$HAS_TERMINAL"; then
        printf "\n" # Move to a new line after the progress bar
    fi

    # 1. Remove the temporary file used for write permission testing.
    if [[ -n "${TEMP_WRITE_TEST_FILE}" && -f "${TEMP_WRITE_TEST_FILE}" ]]; then
        command rm -f "${TEMP_WRITE_TEST_FILE}" || true
    fi

    # 2. Terminate the background counter reader process if it's running.
    if [[ -n "$COUNTER_READER_PID" ]]; then
        if command ps -p "$COUNTER_READER_PID" > /dev/null; then
            command kill -SIGTERM "${COUNTER_READER_PID}"
            if ! command wait "${COUNTER_READER_PID}" 2>/dev/null; then
                command kill -SIGKILL "${COUNTER_READER_PID}"
                command wait "${COUNTER_READER_PID}" 2>/dev/null
            fi
        fi
    fi

    # 3. Remove the FIFO (named pipe) file to clean up temporary resources.
    if [ -p "$FIFO_PATH" ]; then
        command rm -f "${FIFO_PATH}"
    fi

    exit 0
}

# Trap the SIGINT (Ctrl+C), SIGTERM (standard kill command), and EXIT (any script exit) signals
# to ensure the cleanup function is always called.
trap cleanup SIGINT SIGTERM EXIT

# check_commands:
# Verifies the existence of all essential external commands required by the script.
check_commands() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            printf "[ERROR] Required command '%s' not found. Please install it or ensure it's in your PATH.\n" "$cmd" >&2
            exit 1
        fi
    done
}

# generate_lowercase_hex_string:
# Generates a cryptographically secure random hexadecimal string of a specified length.
generate_lowercase_hex_string() {
    local requested_length="$1"
    local num_bytes=$(( (requested_length + 1) / 2 ))
    local result

    result=$(command openssl rand -hex "${num_bytes}" | command head -c "${requested_length}")

    if [[ ${#result} -ne "${requested_length}" ]]; then
        printf "[ERROR] Failed to generate a %s-character random string. This indicates a critical issue with the random number generator.\n" "${requested_length}" >&2
        exit 1
    fi
    command printf "%s" "$result"
}

# is_image_file:
# Checks if a given file's lowercase extension matches any of the predefined
# supported image extensions.
is_image_file() {
    local extension_lower="$1"
    local ext
    for ext in "${IMAGE_EXTENSIONS[@]}"; do
        if [[ "${extension_lower}" == "${ext}" ]]; then
            return 0
        fi
    done
    return 1
}

# update_progress_bar:
# Updates the in-place progress bar in the terminal.
update_progress_bar() {
    if "$HAS_TERMINAL"; then
        local percent=0
        if [[ "${TOTAL_FILES}" -gt 0 ]]; then
            percent=$(( (PROCESSED_FILES * 100) / TOTAL_FILES ))
        fi
        command printf "\r%s\rProgress: %d/%d files processed (%d%%)" \
            "$(command tput el)" "${PROCESSED_FILES}" "${TOTAL_FILES}" "${percent}"
    fi
}

# --- Background Counter Reader Function ---
run_counter_reader() {
    while true; do
        if command read -r line < "$FIFO_PATH"; then
            case "$line" in
                RENAMED|SKIPPED|FAILED)
                    # These signals are consumed by the FIFO but no specific action is needed in this background function.
                    ;;
                END_SIGNAL)
                    break
                    ;;
            esac
        else
            break # Read failed, likely main script terminated unexpectedly
        fi
        command sleep 0.05
    done
}

# ==============================================================================
# 4. Command Pre-checks
# ==============================================================================
check_commands "find" "mv" "head" "tr" "openssl" "basename" "readlink" "rm" "touch" "sleep" "printf" "echo" "tput" "ps" "kill" "mkfifo" "wait"

# ==============================================================================
# 5. Argument Parsing
# ==============================================================================
if [[ "$#" -ne 1 ]]; then
    printf "[ERROR] Incorrect number of arguments. Usage: %s <folder_path>\n" "$0" >&2
    exit 1
fi
folder_path="$1"

# ==============================================================================
# 6. Initial Validation
# ==============================================================================
if [[ "$EUID" -eq 0 ]]; then
    printf "[WARNING] Running this script as root (UID 0) is generally not recommended unless strictly necessary for permissions. Proceeding...\n" >&2
fi
resolved_path=""
if command -v realpath &>/dev/null; then
    resolved_path=$(command realpath "${folder_path}" 2>/dev/null || true)
else
    resolved_path=$(command readlink -f "${folder_path}" 2>/dev/null || true)
fi
if [[ -z "$resolved_path" ]]; then
    printf "[ERROR] Invalid folder path: '%s'. Path does not exist or is inaccessible.\n" "${folder_path}" >&2
    exit 1
fi
folder_path="${resolved_path}"
if [[ ! -d "${folder_path}" ]]; then
  printf "[ERROR] '%s' is not a valid directory.\n" "${folder_path}" >&2
  exit 1
fi
if [[ ! -w "${folder_path}" || ! -x "${folder_path}" ]]; then
    printf "[ERROR] Insufficient permissions for directory: '%s'. Need write and execute permissions.\n" "${folder_path}" >&2
    exit 1
fi
TEMP_WRITE_TEST_FILE="${folder_path}/.test_write.$RANDOM.$$.tmp"
if ! command touch "${TEMP_WRITE_TEST_FILE}" 2>/dev/null; then
    printf "[ERROR] Cannot create files in directory: '%s'. Please check permissions.\n" "${folder_path}" >&2
    exit 1
fi

# ==============================================================================
# 7. Prepare for Progress Bar & Main Logic
# ==============================================================================
if [[ -t 1 ]]; then
    HAS_TERMINAL=true
    command tput init || true
fi

# Create FIFO (named pipe) for inter-process communication.
command rm -f "${FIFO_PATH}"
if ! command mkfifo "${FIFO_PATH}"; then
    printf "[ERROR] Failed to create FIFO at %s. Check permissions or disk space.\n" "${FIFO_PATH}" >&2
    exit 1
fi

# Start the Counter Reader in the background.
run_counter_reader &
COUNTER_READER_PID=$!

# Populate eligible_files array with paths of supported image files.
# This loop now directly identifies image files by extension, without
# checking for existing UUID-like names.
mapfile -t -d '' eligible_files < <(
    find "${folder_path}" -maxdepth 1 -type f -print0 | \
    while IFS= read -r -d $'\0' filepath; do
        filename=$(command basename -- "${filepath}")
        extension="${filename##*.}"
        if [[ "$filename" == "$extension" ]]; then
            extension=""
        fi
        extension_lower=$(command echo "${extension}" | command tr '[:upper:]' '[:lower:]')

        if is_image_file "${extension_lower}"; then
            command printf "%s\0" "${filepath}"
        fi
    done
)
# Get the correct total count from the populated array.
TOTAL_FILES=${#eligible_files[@]}

if [[ "${TOTAL_FILES}" -eq 0 ]]; then
    echo "No supported image files found in '${folder_path}' to rename. Exiting."
    echo "END_SIGNAL" > "$FIFO_PATH" || true
    exit 0
fi

# ==============================================================================
# 8. Main Logic: Image Renaming with Silent Retries
# ==============================================================================
# Initialize progress bar
update_progress_bar

# Iterate over eligible files and rename them.
for filepath in "${eligible_files[@]}"; do
    filename=$(command basename -- "${filepath}")
    extension="${filename##*.}"

    uuid_raw=$(generate_lowercase_hex_string "${UUID_RAW_LENGTH}")
    if [[ ${#uuid_raw} -ne "${UUID_RAW_LENGTH}" ]]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        PROCESSED_FILES=$((PROCESSED_FILES + 1))
        update_progress_bar
        printf "[WARNING] Could not generate valid UUID for '%s'. Skipping.\n" "${filename}" >&2
        echo "SKIPPED" > "$FIFO_PATH" || true
        continue
    fi

    part1=${uuid_raw:0:6}
    part2=${uuid_raw:6:8}
    part3=${uuid_raw:14:8}
    part4=${uuid_raw:22:8}
    part5=${uuid_raw:30:8}
    part6=${uuid_raw:38:6}
    part7=${uuid_raw:44:4}

    new_filename="${part1}-${part2}-${part3}-${part4}-${part5}-${part6}-${part7}.${extension}"
    new_filepath="${folder_path}/${new_filename}"

    attempt=0
    mv_success=false
    while [[ "$attempt" -lt "${MAX_RETRIES}" ]]; do
        MV_ERROR_OUTPUT=$(command mv "${filepath}" "${new_filepath}" 2>&1)
        MV_EXIT_CODE=$?

        if [[ "$MV_EXIT_CODE" -eq 0 ]]; then
            mv_success=true
            break
        else
            attempt=$((attempt + 1))
            printf "[WARNING] Rename attempt %d for '%s' failed (Exit Code: %d). Error: %s. Retrying in %d second(s)...\n" \
                "$attempt" "${filename}" "$MV_EXIT_CODE" "${MV_ERROR_OUTPUT}" "${RETRY_DELAY_SECONDS}" >&2
            if [[ "$attempt" -lt "${MAX_RETRIES}" ]]; then
                command sleep "${RETRY_DELAY_SECONDS}"
            fi
        fi
    done

    if "$mv_success"; then
        RENAMED_COUNT=$((RENAMED_COUNT + 1))
        echo "RENAMED" > "$FIFO_PATH" || true # Still send for FIFO logic, even if not used in progress bar
    else
        FAILED_COUNT=$((FAILED_COUNT + 1))
        printf "[ERROR] Failed to rename '%s' to '%s' after %d attempts.\n" "${filename}" "${new_filename}" "${MAX_RETRIES}" >&2
        echo "FAILED" > "$FIFO_PATH" || true
    fi

    PROCESSED_FILES=$((PROCESSED_FILES + 1))
    update_progress_bar
done

# Send final signal to counter reader to terminate gracefully.
echo "END_SIGNAL" > "$FIFO_PATH" || true

# Cleanup trap will handle the rest upon script exit.
