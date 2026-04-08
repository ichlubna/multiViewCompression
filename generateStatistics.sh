#!/bin/bash

DIR="results"

# Check if the directory exists
if [ ! -d "$DIR" ]; then
    echo "Directory $DIR does not exist."
    exit 1
fi

declare -A configurations
declare -A resolutions
declare -A aggregated

# Loop through each subdirectory in the results directory
for subdir in "$DIR"/*; do
    if [ -d "$subdir" ]; then
        COUNT=$(ls $subdir/*.png 2>/dev/null | wc -l)
        shopt -s nullglob
        FILES=($subdir/*.png)
        read WIDTH HEIGHT < <(identify -format "%w %h" "${FILES[0]}")
        echo "Processing ${subdir}: ${COUNT} views, resolution ${WIDTH}x${HEIGHT}"
        # Statistics
        key=$COUNT
        if [ -z "${configurations[$key]}" ]; then
            configurations[$key]=0
        fi
        configurations[$key]=$((configurations[$key] + 1))

        key="$WIDTH:$HEIGHT"
        if [ -z "${resolutions[$key]}" ]; then
            resolutions[$key]=0
        fi
        resolutions[$key]=$((resolutions[$key] + 1))

        key="$WIDTH:$HEIGHT:$COUNT"
        if [ -z "${aggregated[$key]}" ]; then
            aggregated[$key]=0
        fi
        aggregated[$key]=$((aggregated[$key] + 1))
    fi
done

# Print statistics to CSV
CSV_OUT="results/stats-configurations.csv"
echo "views,occurence" > $CSV_OUT
for key in "${!configurations[@]}"; do
    echo "$key,${configurations[$key]}" >> $CSV_OUT
done

CSV_OUT="results/stats-resolutions.csv"
echo "resolution,occurence" > $CSV_OUT
for key in "${!resolutions[@]}"; do
    echo "$key,${resolutions[$key]}" >> $CSV_OUT
done

CSV_OUT="results/stats-aggregated.csv"
echo "aggregated,occurence" > $CSV_OUT
for key in "${!aggregated[@]}"; do
    echo "$key,${aggregated[$key]}" >> $CSV_OUT
done
