#!/bin/bash

# Parameters
# The directory contains subirectories with the views, one subdirectory per scene, the views should be named as 0001.png, 0002.png...
INPUT_DIR=$1
# Path to the csv files with the results
OUTPUT_DIR=$2

# Set paths to the external tools used
# Binaries:
# https://ffmpeg.org
FFMPEG=ffmpeg
# https://github.com/libjxl/libjxl
JXL_ENCODER=cjxl
JXL_DECODER=djxl
# Paths

set -ex

if [ $# -ne 2 ]; then
    echo "Usage: $0 <input_dir> <output_dir>"
    exit 1
fi

declare -A LOG
LOG['single']="$OUTPUT_DIR/single.csv"
LOG['stereoClose']="$OUTPUT_DIR/stereoClose.csv"
LOG['stereoFar']="$OUTPUT_DIR/stereoFar.csv"
LOG['multi']="$OUTPUT_DIR/multi.csv"
LOG['multiInterpolatedHalf']="$OUTPUT_DIR/multiInterpolatedHalf.csv"
LOG['multiInterpolatedFull']="$OUTPUT_DIR/multiInterpolatedFull.csv"

HEADER="scene, quality, compression, codecQuality, SSIM, PSNR, VMAF, encode time, decode time, size"
for KEY in "${!LOG[@]}"; do
    >${LOG[$KEY]}
    echo $HEADER >> ${LOG[$KEY]}
done

SCENES=($(ls "$INPUT_DIR" | sort))
TEMP=$(mktemp -d)

codecQuality() 
{
    local Q=$(echo $1*$2 | bc)
    echo $Q
}

size() 
{
    local SIZE=$(du -hsb "$1" | cut -f 1)
    echo $SIZE
}

quality()
{
    local DIR="$(cd "$(dirname "$0")" && pwd)"
    local METRICS=$("$DIR/metrics.sh" $1 $2)
    echo $METRICS
}

filePattern()
{
    local DIR="$(cd "$(dirname "$0")" && pwd)"
    local PATTERN=$("$DIR/guessFilePattern.sh" $1)
    echo $PATTERN
}

now()
{
    echo $(date +%s%N)
}

elapsed()
{
    local START=$1
    local END=$2
    echo $(( (END - START)/1000000 ))
}

encode()
{
    local METHOD=$1
    local INPUT=$2
    local QUALITY=$3
    local OUTPUT=$4
    local COUNT=$(ls $SCENE -1 | wc -l)

    if [ $METHOD == "jxl" ]; then 
        local PATTERN=$(filePattern "$INPUT")
        local INPUT_FILE="$INPUT/reference.apng"
        local OUTPUT_FILE="$OUTPUT/encoded.jxl"
        "$FFMPEG" -y -i "$PATTERN" "$INPUT_FILE"
        local MAX_Q=100 
        local Q=$(codecQuality $QUALITY $MAX_Q)
        local START=$(now)
        "$JXL_ENCODER" "$INPUT_FILE" "$OUTPUT_FILE" -q $Q --lossless_jpeg=0 -e 10
        local END=$(now)
    else
        echo "Unsupported codec: $METHOD"
    fi
    echo $(elapsed $START $END)
}

decode()
{
    local METHOD=$1
    local INPUT=$2
    local OUTPUT=$3
    if [ $METHOD == "jxl" ]; then 
        local FILES=($(ls "$INPUT" | sort))
        local START=$(now)
        "$JXL_DECODER" "$INPUT/${FILES[0]}" "$OUTPUT/decoded.apng"
        local END=$(now)
    else
        echo "Unsupported codec: $METHOD"
    fi
    echo $(elapsed $START $END)
}

clearDirs()
{
    rm -rf "$@"
    mkdir -p "$@" 
}

evaluate()
{
    local METHOD=$1
    local SCENE=$2
    local QUALITY=$3
    local COUNT=$(ls "$SCENE" -1 | wc -l)
    local CENTER=$(($COUNT / 2))
    local FILES=($(ls "$SCENE" | sort))
    EXT="${FILES[0]##*.}"
    local REFERENCE="$TEMP/reference"
    local ENCODED="$TEMP/encoded"
    local DECODED="$TEMP/decoded"

    clearDirs "$ENCODED" "$DECODED" "$REFERENCE"
    cp "$SCENE/${FILES[$CENTER]}" "$REFERENCE/0001.$EXT"
    ENCODE_TIME=$(encode $METHOD "$REFERENCE" $QUALITY "$ENCODED")
    DECODE_TIME=$(decode $METHOD "$ENCODED" "$DECODED")
    SIZE=$(size "$ENCODED")
    METRICS=$(quality "$REFERENCE" "$DECODED")
    echo $SCENE, $QUALITY, $METHOD, $METRICS, $ENCODE_TIME, $DECODE_TIME, $SIZE >> ${LOG['single']} 
}

measure()
{
    local SCENE=$1
    local METHODS=("jxl")
    for METHOD in "${METHODS[@]}"; do
        for QUALITY in $(seq 0.0 0.1 1); do
            evaluate $METHOD "$SCENE" $QUALITY
        done
    done
}

for SCENE in $SCENES; do
    measure "$INPUT_DIR/$SCENE"
done

rm -rf $TEMP
