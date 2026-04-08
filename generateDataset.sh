#!/bin/bash

# Do not change
cursor=0
count=0

# A number of API requests, cca number of quilts to be downloaded
MAX_QUILTS=20

ssim_all() {
    #ffmpeg -y -i "$1" -i "$2" -lavfi ssim -f null - 2>&1 \
    ffmpeg -y -i "$1" -i "$2" -filter_complex "[1:v]scale=$3:$4:flags=bicubic[scaled];[0:v][scaled]ssim" -f null - 2>&1 \
        | grep -oP 'All:\K[0-9.]+'
}

#if false; then

rm urls.txt
rm list.txt
rm -rf tmp

# Gather URLs using API
while true; do
    echo "Cursor: $cursor" >&2

    input=$(jq -nc \
      --argjson cursor "$cursor" \
      '{
        json: {
          type: "QUILT",
          showShadowBannedContent: false,
          cursor: $cursor,
          direction: "forward"
        }
      }' | jq -sRr @uri)

    echo $input
    response=$(curl -s "https://blocks.glass/api/trpc/hologram.discoverFeed?input=$input")

    # Extract image URLs
    echo "$response" >> urls.txt

    # Get next cursor
    next_cursor=$(echo "$response" | jq -r '.. | .nextCursor? // empty' | tail -n1)

    # Stop if no more data
    if [ -z "$next_cursor" ] || [ "$next_cursor" = "null" ]; then
        break
    fi

    count=$((count+1))

    if [[ $count -ge ${MAX_QUILTS} ]]; then
        break
    fi

    cursor=$next_cursor

    sleep 0.5
done

# Download
grep -oP '"url":"\Khttps://s3[^"]+qs[0-9]+x[0-9]+a[^"]+\.png' urls.txt | grep -v 'source\.png$' \
    | sort -u > list.txt

mkdir tmp/
cd tmp/
wget -i ../list.txt
cd ..

#fi

# Rename and divide into single views
rm -rf results
mkdir results
COUNTER=1

files=()

for file in tmp/*; do
    echo "${COUNTER}. Processing ${file}"
    mkdir -p "results/${COUNTER}"
    if [[ $file =~ qs([0-9]+)x([0-9]+)a ]]; then
        COLS=${BASH_REMATCH[1]}
        ROWS=${BASH_REMATCH[2]}

        # Check if there already was the same image with SSIM comparison
        # Loop over all files different than the current one and check if they are similar enough
        read WIDTH HEIGHT < <(identify -format "%w %h" "$file")

        for other in "${files[@]}"; do
            #if [[ "$other" != "$file" ]]; then
            if [[ $other =~ qs([0-9]+)x([0-9]+)a ]]; then
                C2=${BASH_REMATCH[1]}
                R2=${BASH_REMATCH[2]}

                #read W2 H2 < <(identify -format "%w %h" "$other")

                # If same dimensions, check for SSIM
                if [[ "$COLS" -ne "$C2" ]] || [[ "$ROWS" -ne "$R2" ]]; then
                    continue
                fi

                SSIM=$(ssim_all $file $other $WIDTH $HEIGHT)
                if [ "$(echo "$SSIM > 0.99" | bc -l)" -eq 1 ]; then
                    echo "- Skipping ${file} because it is similar to ${other} with SSIM: $SSIM"
                    continue 2
                fi
                #echo "- - SSIM: ${SSIM} between ${file} and ${other}"
            fi
        done

        TILE_W=$((WIDTH / COLS))
        TILE_H=$((HEIGHT / ROWS))

        index=1

        for ((row=ROWS-1; row>=0; row--)); do  # bottom → top
            for ((col=0; col<COLS; col++)); do # left → right

                x=$((col * TILE_W))
                y=$((row * TILE_H))
                printf -v name "%04d.png" "$index"
                convert "$file" -crop "${TILE_W}x${TILE_H}+${x}+${y}" +repage "results/$COUNTER/$name"

                # Check if first or last image is black, if so, delete them
                if [ "$index" -eq 1 ] || [ "$index" -eq $((COLS*ROWS)) ]; then
                    mean=$(magick "results/$COUNTER/$name" -colorspace Gray -format "%[fx:mean]" info:)
                    if (( $(echo "$mean == 0" | bc -l) )); then
                        rm "results/$COUNTER/$name"
                        #echo "- Deleted ${name} because it is black with mean: $mean"
                        continue
                    fi
                fi

                ((index++))
            done
        done
        files+=("$file")
        echo "Processed ${file} and added to files."
    fi
    COUNTER=$((COUNTER+1))
done
