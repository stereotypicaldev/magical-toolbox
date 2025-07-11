#!/bin/bash

# --- Configuration & Constants ---
# Common image file extensions (case-insensitive)
declare -ra IMAGE_EXTENSIONS=(
    "jpg" "jpeg" "png" "gif" "bmp" "tiff" "webp" "heic" "heif"
)

# Fixed length for UUID-like string
readonly FIXED_UUID_LENGTH=64
# Minimum segment length between dashes
readonly MIN_SEGMENT_LENGTH=5
# Maximum segment length between dashes
readonly MAX_SEGMENT_LENGTH=6
# Fixed length for non-bar info in progress display (e.g., "[ ] 100% (999/9999)")
readonly PROGRESS_INFO_LENGTH_ESTIMATE=25
# Minimum allowed progress bar length
readonly MIN_PROGRESS_BAR_LENGTH=5

# --- Global Command Paths (Dynamically Discovered) ---
# These variables will store the full path to commands for robustness
# Using 'command -v' is safer than hardcoding paths.
declare -r TR_CMD=$(command -v tr 2>/dev/null)
declare -r HEAD_CMD=$(command -v head 2>/dev/null)
declare -r TPUT_CMD=$(command -v tput 2>/dev/null)
declare -r SHASUM_CMD=$(command -v shasum 2>/dev/null)
declare -r MD5SUM_CMD=$(command -v md5sum 2>/dev/null)
declare -r MV_CMD=$(command -v mv 2>/dev/null)
declare -r CP_CMD=$(command -v cp 2>/dev/null)
declare -r RM_CMD=$(command -v rm 2>/dev/null)
declare -r FIND_CMD=$(command -v find 2>/dev/null) # Added find for explicit path
declare -r REALPATH_CMD=$(command -v realpath 2>/dev/null)
declare -r READLINK_CMD=$(command -v readlink 2>/dev/null)
declare -r DIRNAME_CMD=$(command -v dirname 2>/dev/null)

# --- Utility Functions ---

# Function to generate a cryptographically secure UUID-like string with varying length
# Uses /dev/urandom for stronger randomness.
# SECURITY: Added explicit checks for command existence before use.
generate_uuid_like() {
    local length="${FIXED_UUID_LENGTH}"
    local raw_hex=""

    # Attempt to read from /dev/urandom for robustness
    if [ -n "$HEAD_CMD" ] && [ -n "$TR_CMD" ]; then
        raw_hex=$("$HEAD_CMD" /dev/urandom | "$TR_CMD" -dc 'a-f0-9' | "$HEAD_CMD" -c "$length" 2>/dev/null)
    else
        # Fallback for systems without head/tr (unlikely for modern Linux/macOS)
        # Suppress od errors, which might occur on non-standard /dev/urandom reads
        raw_hex=$(cat /dev/urandom 2>/dev/null | od -x -w16 -v 2>/dev/null | "$HEAD_CMD" -c "$length" 2>/dev/null | "$TR_CMD" -dc 'a-f0-9' 2>/dev/null)
    fi

    # If raw_hex is still empty, attempt a final, less secure fallback
    if [ -z "$raw_hex" ]; then
        # Use shasum/md5sum as a last resort, relying on system commands
        if [ -n "$SHASUM_CMD" ]; then
            raw_hex=$(date +%s%N | "$SHASUM_CMD" -a 256 | "$HEAD_CMD" -c "$length" | "$TR_CMD" -dc 'a-f0-9' 2>/dev/null)
        elif [ -n "$MD5SUM_CMD" ]; then
            raw_hex=$(date +%s%N | "$MD5SUM_CMD" | "$HEAD_CMD" -c "$length" | "$TR_CMD" -dc 'a-f0-9' 2>/dev/null)
        else
            # Extremely unlikely, but as a final, final resort, use RANDOM.
            # This is NOT cryptographically secure.
            local i=0
            while [ "$i" -lt "$length" ]; do
                raw_hex+=$(printf '%x' $(( RANDOM % 16 )))
                i=$((i + 1))
            done
            raw_hex=$("$HEAD_CMD" -c "$length" <<< "$raw_hex") # Use head with heredoc for robustness
            echo >&2 "Warning: Using insecure fallback for UUID generation (RANDOM)."
        fi
    fi

    local final_uuid=""
    local current_segment_len=0
    local total_processed_len=0

    # Ensure raw_hex is not empty after all attempts
    if [ -z "$raw_hex" ]; then
        echo >&2 "Error: Could not generate any hexadecimal string for UUID after multiple attempts. This is a critical failure."
        return 1 # Indicate failure to the caller
    fi

    for (( i=0; i<${#raw_hex}; i++ )); do
        final_uuid+="${raw_hex:i:1}"
        current_segment_len=$((current_segment_len + 1))
        total_processed_len=$((total_processed_len + 1))

        # Calculate remaining characters in the raw_hex string
        local remaining_chars=$(( length - total_processed_len ))

        # Determine if a dash should be added
        if (( current_segment_len == MAX_SEGMENT_LENGTH )) && (( remaining_chars >= MIN_SEGMENT_LENGTH )); then
            final_uuid+="-"
            current_segment_len=0 # Reset segment length after a dash
        elif (( current_segment_len >= MIN_SEGMENT_LENGTH )) && (( remaining_chars < MIN_SEGMENT_LENGTH )); then
            if (( remaining_chars > 0 )); then # Only add a dash if there are still characters to follow it
                final_uuid+="-"
                current_segment_len=0 # Reset segment length
            fi
        fi
    done

    echo "$final_uuid"
    return 0 # Indicate success
}

# ---
## Progress Bar Display
# Arguments: current_count, total_count
display_progress() {
    local current=$1
    local total=$2

    local terminal_width=$("$TPUT_CMD" cols 2>/dev/null)
    # Validate terminal_width is a number and greater than 0
    if ! [[ "$terminal_width" =~ ^[0-9]+$ ]] || [ "$terminal_width" -eq 0 ]; then
        terminal_width=80 # Default width if tput fails or not a TTY or provides bad output
    fi

    local max_bar_length=$(( terminal_width - PROGRESS_INFO_LENGTH_ESTIMATE ))
    if (( max_bar_length < MIN_PROGRESS_BAR_LENGTH )); then
        max_bar_length=$MIN_PROGRESS_BAR_LENGTH
    fi

    local progress=$(( (current * 100) / total ))
    local filled_length=$(( (max_bar_length * progress) / 100 ))
    local empty_length=$(( max_bar_length - filled_length ))

    local filled_bar=$(printf "%${filled_length}s" | "$TR_CMD" ' ' '#')
    local empty_bar=$(printf "%${empty_length}s" | "$TR_CMD" ' ' '.')

    printf "\033[2K\r[%s%s] %d%% (%d/%d)" "$filled_bar" "$empty_bar" "$progress" "$current" "$total"
}

# Function to display an error message and exit
# Arguments: error_message, exit_code
# SECURITY: Using '>&2' for all error output and 'exit' for controlled termination.
error_exit() {
    echo -e "\n\033[0;31mError:\033[0m $1" >&2 # Red error message to stderr
    exit "${2:-1}" # Exit with provided code or default to 1
}

# Function to attempt renaming using different methods
# Arguments: source_path, destination_path
# FOOLPROOFING: Tries multiple rename methods for resilience.
# SECURITY: Uses explicit command paths and -- for path safety.
robust_rename() {
    local source_path="$1"
    local dest_path="$2"
    local success=false

    # Attempt 1: mv -n (no-clobber, preferred)
    if [ -n "$MV_CMD" ] && "$MV_CMD" -n -- "$source_path" "$dest_path" 2>/dev/null; then
        success=true
    else
        # Attempt 2: mv (without -n, in case -n isn't supported or file was removed then recreated)
        if [ -n "$MV_CMD" ] && "$MV_CMD" -- "$source_path" "$dest_path" 2>/dev/null; then
            success=true
        else
            # Attempt 3: If 'mv' fails, try 'cp' then 'rm'
            if [ -n "$CP_CMD" ] && "$CP_CMD" -p -- "$source_path" "$dest_path" 2>/dev/null; then
                if [ -n "$RM_CMD" ] && "$RM_CMD" -- "$source_path" 2>/dev/null; then
                    success=true
                # else: rm failed but cp succeeded (partial success, file duplicated)
                # This warning is captured by the 'failed_renames' array in main
                fi
            fi
        fi
    fi
    echo "$success" # Return true/false string
}

# ---
## Main Script Logic
main() {
    # Set strict error handling for initial checks, but allow robustness later
    # 'set -u' (unset variables), 'set -e' (exit on error), 'set -o pipefail' (fail pipelines)
    # SECURITY: Using 'set -o nounset' for clarity and error detection for unset variables.
    set -euo pipefail
    # IFS (Internal Field Separator) is set to newline and tab only.
    # SECURITY: Helps prevent arbitrary code execution via crafted filenames containing spaces.
    IFS=$'\n\t'

    # Array to store failed renames for reporting
    local failed_renames=()

    # --- Pre-flight Checks: Ensure critical commands are available ---
    # FOOLPROOFING: Checks for essential external commands upfront.
    local missing_cmds=()
    if [ -z "$TR_CMD" ]; then missing_cmds+=("tr"); fi
    if [ -z "$HEAD_CMD" ]; then missing_cmds+=("head"); fi
    if [ -z "$TPUT_CMD" ]; then missing_cmds+=("tput"); fi
    if [ -z "$MV_CMD" ]; then missing_cmds+=("mv"); fi
    if [ -z "$CP_CMD" ]; then missing_cmds+=("cp"); fi
    if [ -z "$RM_CMD" ]; then missing_cmds+=("rm"); fi
    if [ -z "$FIND_CMD" ]; then missing_cmds+=("find"); fi # Explicitly check for find
    if [ -z "$REALPATH_CMD" ] && [ -z "$READLINK_CMD" ]; then missing_cmds+=("realpath or readlink"); fi
    if [ -z "$DIRNAME_CMD" ]; then missing_cmds+=("dirname"); fi

    if [ "${#missing_cmds[@]}" -gt 0 ]; then
        error_exit "Missing essential commands: ${missing_cmds[*]} (Please ensure coreutils, ncurses-bin are installed and in PATH)." 1
    fi
    # --- End Pre-flight Checks ---

    # Check for argument
    if [ "$#" -ne 1 ]; then
        error_exit "Usage: $0 <folder_path>\n\n  Please provide exactly one folder path as an argument." 1
    fi

    local folder_path="$1"

    # Input validation: Check if folder exists and is a directory
    # FOOLPROOFING: Strict input validation.
    if [ ! -d "$folder_path" ]; then
        error_exit "Folder '$folder_path' not found or is not a directory. Please provide a valid folder path." 1
    fi

    # Resolve symbolic links and get the canonical path for security
    # SECURITY: Prevents path traversal via symbolic links or unexpected directory behavior.
    local resolved_path=""
    if [ -n "$REALPATH_CMD" ]; then
        resolved_path=$("$REALPATH_CMD" -q "$folder_path" 2>/dev/null)
    fi
    if [ -z "$resolved_path" ] && [ -n "$READLINK_CMD" ]; then
        resolved_path=$("$READLINK_CMD" -f "$folder_path" 2>/dev/null)
    fi

    if [ -z "$resolved_path" ] || [ ! -d "$resolved_path" ]; then
        error_exit "Failed to resolve canonical path for '$1' or path became invalid. Check permissions or path validity." 1
    fi
    folder_path="$resolved_path" # Update folder_path to the resolved one

    # Check if the folder is writable and executable (for listing contents)
    # FOOLPROOFING: Ensures necessary permissions for operations.
    if [ ! -w "$folder_path" ] || [ ! -x "$folder_path" ]; then
        error_exit "Folder '$folder_path' is not writable or readable/executable. Please check permissions." 1
    fi

    local image_files=()
    local find_args=()

    # Build the find command arguments dynamically for robustness
    for ext in "${IMAGE_EXTENSIONS[@]}"; do
        find_args+=("-o" "-iname" "*.$ext")
    done
    # Remove the leading -o if it exists (first element)
    if [ "${#find_args[@]}" -gt 0 ]; then
        find_args=("${find_args[@]:1}")
    fi

    # Use 'find' for robustness with spaces and special characters in filenames.
    # Use -print0 and read -d $'\0' for null-terminated strings to handle all filenames correctly.
    # Add -maxdepth 1 to only process files directly in the specified folder, not subdirectories.
    # Redirect stderr to /dev/null for all find commands.
    # SECURITY: Using null-terminated strings (-print0) for filenames is crucial against injection.
    while IFS= read -r -d $'\0' file; do
        # Basic check to ensure it's a regular file (find -type f already does this, but for belt-and-subfolders)
        # and it's readable
        if [ -f "$file" ] && [ -r "$file" ]; then
            image_files+=("$file")
        fi
    done < <("$FIND_CMD" "$folder_path" -maxdepth 1 -type f \( "${find_args[@]}" \) -print0 2>/dev/null)

    local total_files=${#image_files[@]}

    if [ "$total_files" -eq 0 ]; then
        echo "No supported image files found in '$folder_path'. Script finished."
        exit 0
    fi

    local count=0
    for file_path in "${image_files[@]}"; do
        count=$((count + 1))
        display_progress "$count" "$total_files"

        # Check if the file still exists and is readable just before processing
        # FOOLPROOFING: Prevents attempts to operate on files that disappeared or changed.
        if [ ! -f "$file_path" ] || [ ! -r "$file_path" ]; then
            failed_renames+=("Skipped: '$file_path' (Reason: File disappeared or became unreadable during processing)")
            continue
        fi

        # Extract directory and extension safely
        local dir_name
        # Use the dynamically discovered dirname command
        dir_name=$("$DIRNAME_CMD" -- "$file_path") # Use -- to handle paths starting with -
        local original_extension
        original_extension="${file_path##*.}"

        # Sanitize extension: only append if it looks like a valid extension
        # SECURITY/FOOLPROOFING: Prevents malformed extensions from causing issues.
        if [[ "$file_path" == *.* ]] && [[ "$original_extension" =~ ^[a-zA-Z0-9]+$ ]] && [[ ${#original_extension} -le 10 ]]; then
            # Looks like a proper extension, keep it. Max 10 chars for sanity.
            true
        else
            original_extension="" # No valid extension or too long, do not append
        fi

        local new_filename=""
        local new_file_path=""
        local attempts=0
        local max_attempts=500 # Increased attempts for robustness
        local uuid_generated_successfully=false

        # Loop until a unique filename is generated or max attempts reached
        # PRIVACY: Generates unique names to avoid revealing original naming patterns.
        # FOOLPROOFING: Retries name generation to avoid collisions.
        while true; do
            # Capture stdout of generate_uuid_like into new_filename
            new_filename=$(generate_uuid_like)
            local uuid_gen_status=$? # Capture the exit status

            if [ "$uuid_gen_status" -eq 0 ] && [ -n "$new_filename" ]; then
                uuid_generated_successfully=true
            else
                failed_renames+=("Internal Error: Failed to generate UUID for '$file_path'. Skipping.")
                uuid_generated_successfully=false
                break # Break if UUID generation itself fails
            fi

            if [ -n "$original_extension" ]; then
                new_file_path="${dir_name}/${new_filename}.${original_extension}"
            else
                new_file_path="${dir_name}/${new_filename}" # No extension to append
            fi

            # Check if the newly generated path already exists - critical for uniqueness
            if [ ! -e "$new_file_path" ]; then
                break # Found a unique name
            fi

            attempts=$((attempts + 1))
            if (( attempts >= max_attempts )); then
                failed_renames+=("Collision: Could not find unique name for '$file_path' after $max_attempts attempts.")
                uuid_generated_successfully=false # Mark as not generated effectively
                break # Exit inner while loop, mark as failed
            fi
        done

        # If UUID generation or unique name finding failed, skip renaming
        if [ "$uuid_generated_successfully" == false ]; then
            continue # Move to the next file in the outer loop
        fi

        # Attempt to rename using the robust_rename function
        if [ "$(robust_rename "$file_path" "$new_file_path")" = "true" ]; then
            # Success, nothing to do here
            :
        else
            # Rename failed after all attempts
            failed_renames+=("Rename failed: '$file_path' (To: '$new_file_path' - Reason: Multiple attempts failed or permissions issue)")
        fi
    done

    # Final newline after the progress bar is complete
    echo -e "\n"

    # ---
    ## Renaming Report
    # FOOLPROOFING: Provides a clear summary of any issues.
    if [ "${#failed_renames[@]}" -gt 0 ]; then
        echo "---"
        echo -e "\033[0;33mRenaming Report: Some files could not be processed.\033[0m"
        echo "---"
        for entry in "${failed_renames[@]}"; do
            echo "- $entry"
        done
        echo "---"
        echo "Please review the listed issues and retry the script on those files if needed."
        # Exit with a non-zero code to indicate partial failure
        exit 1
    else
        echo "All supported image files processed successfully."
        # Exit with a zero code to indicate full success
        exit 0
    fi
}

# Call the main function with all arguments passed to the script
main "$@"