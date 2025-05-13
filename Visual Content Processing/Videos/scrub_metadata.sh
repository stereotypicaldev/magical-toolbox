exiftool -r -overwrite_original_in_place -ext mp4 -all:all= ~/Downloads/Youtube

for file in ~/Downloads/Youtube/*; do
	ffmpeg -i ~/Downloads/Youtube/"${file##*/}" -map 0 -map_metadata -1 -c copy ~/Downloads/Metadata/"${file##*/}"
done
