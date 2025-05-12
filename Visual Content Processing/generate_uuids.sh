#!/bin/bash

# -----------------------------------------------------------------------------
# Script Name: generate_uuid.sh
# Description: Renames image files (.jpg, .jpeg, .png) in the specified
#              directory (or current directory by default) to unique UUIDs.
#              The UUIDs are 256-bit cryptographically secure values formatted
#              with dashes, ensuring no filename collisions.
#
#
# Usage
#
#
#   ./generate_uuid.sh [directory]
#
#
# Arguments
#
#   directory: Optional. The directory to process. Defaults to the current
#              directory if not provided.
#
#
# Example:
#
#   ./generate_uuid.sh /path/to/images
# -----------------------------------------------------------------------------

# Exit on errors, unset variables, and failed pipelines
set -euo pipefail

# Default to current directory if no argument is provided
directory="${1:-.}"

# Validate that the provided path is a directory
if [[ ! -d "$directory" ]]; then
    echo "Error: '$directory' is not a valid directory." >&2
    exit 1
fi

# Process image files (.jpg, .jpeg, .png) in the specified directory
find "$directory" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -print0 |
    xargs -0 -P 8 -I{} bash -c '
        file="{}"

        # Skip empty or invalid file paths
        if [[ -z "$file" || ! -f "$file" ]]; then
            exit 0
        fi

        # Extract and normalize the file extension
        extension="${file##*.}"
        extension="${extension,,}"  # lowercase

        # Validate allowed extensions
        case "$extension" in
            jpg|jpeg|png) ;;
            *) exit 0 ;;
        esac

        # Generate a 256-bit (32-byte) random value using OpenSSL
        uuid=$(openssl rand -hex 32)

        # Insert dashes to format the UUID as 8-4-4-4-12
        uuid_with_dashes="${uuid:0:8}-${uuid:8:4}-${uuid:12:4}-${uuid:16:4}-${uuid:20:12}"

        # Construct the new file name
        new_file="${file%/*}/$uuid_with_dashes.$extension"

        # Ensure no name collision
        while [[ -e "$new_file" ]]; do
            uuid=$(openssl rand -hex 32)
            uuid_with_dashes="${uuid:0:8}-${uuid:8:4}-${uuid:12:4}-${uuid:16:4}-${uuid:20:12}"
            new_file="${file%/*}/$uuid_with_dashes.$extension"
        done

        # Perform the renaming
        mv -- "$file" "$new_file"
    '
