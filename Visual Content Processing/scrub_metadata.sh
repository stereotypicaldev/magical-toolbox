#!/bin/bash

# Create the output directory if it doesn't exist
mkdir -p scrubbed_images

# Get the total number of images to process (only original images)
total_images=$(find "$1" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.tiff" \) | grep -v '\.cleaned' | wc -l)

# Check if there are no images
if [ "$total_images" -eq 0 ]; then
    echo "No images found to process."
    exit 1
fi

# Set up a counter to track progress
counter=0

# A hash table (file checksum) to store processed images
declare -A processed_images

# Function to display progress bar
show_progress() {
    local progress=$(( ($1 * 100) / $2 ))
    local bar=""
    local width=50
    for ((i=0; i<width; i++)); do
        if [ $i -lt $((progress * width / 100)) ]; then
            bar="${bar}#"
        else
            bar="${bar} "
        fi
    done
    # Print the progress bar with percentage and current photo number
    printf "\r[%-50s] %d%% - Currently processing %d out of %d" "$bar" "$progress" "$1" "$2"
}

# Loop through all original image files in the given directory (excluding .cleaned files)
find "$1" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.tiff" \) | while read img; do
    # Skip if it's a scrubbed/processed image (e.g., *.cleaned)
    [[ "$img" =~ \.cleaned\. ]] && continue  # Skip any scrubbed files

    # Check if the image has already been processed by comparing checksums
    checksum=$(md5sum "$img" | awk '{ print $1 }')

    if [[ ${processed_images[$checksum]} ]]; then
        # If checksum already exists, silently skip processing
        continue
    fi

    # Add checksum to the processed images hash table
    processed_images[$checksum]=1

    # Define temporary filenames in the scrubbed_images folder
    img_basename=$(basename "$img")
    temp1="scrubbed_images/temp1_${img_basename}"
    temp2="scrubbed_images/temp2_${img_basename}"
    temp3="scrubbed_images/temp3_${img_basename}"
    output="scrubbed_images/${img_basename}"

    # Skip if scrubbed image already exists
    if [ -f "$output" ]; then
        # Skip without printing a message and update progress bar
        ((counter++))
        show_progress "$counter" "$total_images"
        continue
    fi

    # Increment the progress counter
    ((counter++))

    # Show progress bar with current counter/total_images
    show_progress "$counter" "$total_images"
    
    # Step 1: Copy original image to scrubbed_images directory
    cp "$img" "$temp1"

    # Step 2: Use mat2 to remove metadata (suppress output)
    if ! mat2 "$temp1" > /dev/null 2>&1; then
        rm -f "$temp1"
        continue
    fi
    mv "${temp1%.*}.cleaned.${temp1##*.}" "$temp1"

    # Step 3: Use exiftool to remove all metadata (suppress output)
    if ! exiftool -all= -overwrite_original "$temp1" > /dev/null 2>&1; then
        rm -f "$temp1"
        continue
    fi
    mv "$temp1" "$temp2"

    # Step 4: Use ImageMagick to strip any remaining metadata (suppress output)
    if ! convert "$temp2" "$temp3" > /dev/null 2>&1; then
        rm -f "$temp2"
        continue
    fi
    rm -f "$temp2"

    # Step 5: Check if the scrubbed image is the same as the original
    if ! cmp -s "$img" "$temp3"; then
        # If they are different, move the scrubbed image to the output directory
        if [ "$temp3" != "$output" ]; then
            mv "$temp3" "$output"
        else
            rm -f "$temp3"
        fi
    else
        # If they are the same, remove the temporary scrubbed image
        rm -f "$temp3"
    fi
done

# Final message
echo -e "\nMetadata removal complete. Scrubbed images are in the 'scrubbed_images' folder."
