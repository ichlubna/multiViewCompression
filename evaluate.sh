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
# https://github.com/bbldcver/EDEN
# Conda setup needs to be prepared for the following tools according to each repository README 
EDEN=EDEN
# https://github.com/KAIST-VICLab/BiM-VFI
BIMVFI=BIMVFI

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

HEADER="scene, quality, compression, SSIM, PSNR, VMAF, FSIM, NAT_DISTS, encode time, decode time, size"
for KEY in "${!LOG[@]}"; do
    >${LOG[$KEY]}
    echo $HEADER >> ${LOG[$KEY]}
done

SCENES=($(ls "$INPUT_DIR" | sort))
TEMP=$(mktemp -d)

codecQuality() 
{
    local Q=$(echo "scale=5; $1*$2" | bc)
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
        local INPUT_FILE="$TEMP/reference.apng"
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

fileName()
{
    local ORIG_FILE=$1
    local NUMBER=$2
    local EXT="${ORIG_FILE##*.}"
    printf -v NEWNAME "%04d.%s" "$NUMBER" "$EXT"
    echo $NEWNAME
}

fileToNumber()
{
    local FILE=$1
    local FILENAME=$(basename "$FILE")
    local NO_EXT="${FILENAME%.*}"
    local NUMBER=$((10#$NO_EXT))
    echo $NUMBER
}

interpolate()
{
    local -n IN_FILES=$1
    local INTERPOLATED_DIR_HALF=$2
    local INTERPOLATED_DIR_FULL=$3
    local METHOD=$4
    local COUNT=${#FILES[@]}
   
    local FINISHED=0 
    local LAST_ID=$(($COUNT - 1))
    clearDirs "$INTERPOLATED_DIR_HALF" "$INTERPOLATED_DIR_FULL"
    if (( COUNT % 2 == 0 )); then
        local LAST_FILE=$(fileName "${IN_FILES[$LAST_ID]}" $(($LAST_ID+1)))
        cp "${IN_FILES[$LAST_ID]}" "$INTERPOLATED_DIR_HALF/$LAST_FILE" 
        cp "${IN_FILES[$LAST_ID]}" "$INTERPOLATED_DIR_FULL/$LAST_FILE" 
        local LAST_ID=$(($LAST_ID - 1))
        local FINISHED=1
    fi
   
    local LAST_FILE=$(fileName "${IN_FILES[$LAST_ID]}" $(($LAST_ID+1)))
    cp "${IN_FILES[$LAST_ID]}" "$INTERPOLATED_DIR_HALF/$LAST_FILE" 
    cp "${IN_FILES[$LAST_ID]}" "$INTERPOLATED_DIR_FULL/$LAST_FILE" 
    local FIRST_FILE=$(fileName "${FILES[0]}" 1)
    cp "${IN_FILES[0]}" "$INTERPOLATED_DIR_HALF/$FIRST_FILE" 
    cp "${IN_FILES[0]}" "$INTERPOLATED_DIR_FULL/$FIRST_FILE" 
  
    local RESULT_DIR=$TEMP/interpolated
    mkdir -p $RESULT_DIR 
    local PAIRS=("$INTERPOLATED_DIR_FULL/$FIRST_FILE $INTERPOLATED_DIR_FULL/$LAST_FILE")
    local FINISHED=$(($FINISHED + 2))
    while (( FINISHED < $COUNT )); do
        local NEW_PAIRS=()
        for PAIR in "${PAIRS[@]}"; do
            read -r FIRST SECOND <<< "$PAIR"
            local FIRST_ID=$( fileToNumber "$FIRST")
            local SECOND_ID=$( fileToNumber "$SECOND")
            local NEW_ID=$((($FIRST_ID + $SECOND_ID) / 2))

            if [ $METHOD == "eden" ]; then 
                cd $EDEN
                conda run -n eden CUDA_VISIBLE_DEVICES=0 python inference.py --frame_0_path $FIRST --frame_1_path $SECOND --interpolated_results_dir $RESULT_DIR 
                local NEW=$(fileName "$RESULT_DIR/interpolated.png" $NEW_ID)
                cp "$RESULT_DIR/interpolated.png" $INTERPOLATED_DIR_FULL/$NEW
                cd - > /dev/null
            else
                local INTER_INPUT_PATH="$TMP/interpolateInput"
                sed -i "s|root_path: ./assets/demo|root_path: $INTER_INPUT_PATH|" cfgs/bim_vfi_demo.yaml
                #TODO extract the frames
                conda run -n bimvfi python main.py --cfg cfgs/bim_vfi_demo.yaml
            fi 

            local NEW_PAIRS+=("$FIRST $INTERPOLATED_DIR_FULL/$NEW")
            local NEW_PAIRS+=("$INTERPOLATED_DIR_FULL/$NEW $SECOND")
            local FINISHED=$(($FINISHED + 1))
        done
        PAIRS=("${NEW_PAIRS[@]}")
    done   
    
    for ((I = 2; I <= $LAST_ID; I += 2)); do
        local FIRST=${IN_FILES[$(($I - 2))]}
        local SECOND=${IN_FILES[$(($I))]}
        local FIRST_ID=$(fileToNumber "$FIRST")
        local SECOND_ID=$(fileToNumber "$SECOND")
        local NEW_FIRST=$(fileName "$FIRST" $FIRST_ID)
        local NEW_SECOND=$(fileName "$SECOND" $SECOND_ID)
        cp "$FIRST" "$INTERPOLATED_DIR_HALF/$NEW_FIRST"
        cp "$SECOND" "$INTERPOLATED_DIR_HALF/$NEW_SECOND"
        cd $EDEN
        conda run -n eden CUDA_VISIBLE_DEVICES=0 python inference.py --frame_0_path $FIRST --frame_1_path $SECOND --interpolated_results_dir $RESULT_DIR 
        local NEW_INTER=$(fileName "$RESULT_DIR/interpolated.png" $(($FIRST_ID + 1)))
        cp "$RESULT_DIR/interpolated.png" $INTERPOLATED_DIR_HALF/$NEW_INTER
        cd - > /dev/null 
    done 
 
exit 1 
}

evaluate()
{
    local METHOD=$1
    local INPUT_SCENE=$2
    local QUALITY=$3

    local SCENE="$TEMP/scene"
    clearDirs "$SCENE"
    local PATTERN=$(filePattern "$INPUT_SCENE")
    $FFMPEG -y -i "$PATTERN" "$SCENE/%04d.png"

    local COUNT=$(ls "$SCENE" -1 | wc -l)
    local CENTER=$(($COUNT / 2))
    local FILES=($(printf "%s\n" "$SCENE"/* | sort))
    local REFERENCE="$TEMP/reference"
    local ENCODED="$TEMP/encoded"
    local DECODED="$TEMP/decoded"   

    local -A REF_FILES
    local ARR=("${FILES[$CENTER]}")
    local REF_FILES['single']=$(printf "%q " "${ARR[@]}")
    local ARR=("${FILES[0]}" "${FILES[1]}")
    local REF_FILES['stereoClose']=$(printf "%q " "${ARR[@]}")
    local ARR=("${FILES[0]}" "${FILES[$(($COUNT - 1))]}")
    local REF_FILES['stereoFar']=$(printf "%q " "${ARR[@]}")
    local REF_FILES['multi']=$(printf "%q " "${FILES[@]}")
    local ARR="$SCENE/${FILES[$CENTER]}"

    local INTERPOLATED_HALF_EDEN="$TEMP/interpolatedHalfEden"
    local INTERPOLATED_FULL_EDEN="$TEMP/interpolatedFullEden"
    local INTERPOLATED_HALF_PERVFI="$TEMP/interpolatedHalfPerVFI"
    local INTERPOLATED_FULL_PERVFI="$TEMP/interpolatedFullPerVFI"
    interpolate FILES "$INTERPOLATED_HALF_EDEN" "$INTERPOLATED_FULL_EDEN" "eden"
    interpolate FILES "$INTERPOLATED_HALF_PERVFI" "$INTERPOLATED_FULL_PERVFI" "pervfi"
    exit 1
    
    REF_FILES['multiInterpolatedHalf']=$(printf "%q " "${ARR[@]}")
    local ARR="$SCENE/${FILES[$CENTER]}"
    REF_FILES['multiInterpolatedFull']=$(printf "%q " "${ARR[@]}")

    for KEY in single stereoClose stereoFar multi; do # multiInterpolatedHalf multiInterpolatedFull; do
        clearDirs "$ENCODED" "$DECODED" "$REFERENCE"
        eval "CURRENT_FILES=(${REF_FILES[$KEY]})"
        I=1
        for FILE in "${CURRENT_FILES[@]}"; do
            local NEWNAME=$(fileName "$FILE" $I)
            cp "$FILE" "$REFERENCE/$NEWNAME"
            ((I++))
        done
        local ENCODE_TIME=$(encode $METHOD "$REFERENCE" $QUALITY "$ENCODED")
        local DECODE_TIME=$(decode $METHOD "$ENCODED" "$DECODED")
        local SIZE=$(size "$ENCODED")
        local METRICS=$(quality "$REFERENCE" "$DECODED")
        echo $SCENE, $QUALITY, $METHOD, $METRICS, $ENCODE_TIME, $DECODE_TIME, $SIZE >> ${LOG["$KEY"]} 
    done
}

measure()
{
    local SCENE=$1
    local METHODS=("jxl")
    for METHOD in "${METHODS[@]}"; do
        for QUALITY in $(seq 0.0 0.1 0.05); do
            evaluate $METHOD "$SCENE" $QUALITY
        done
    done
}

for SCENE in $SCENES; do
    measure "$INPUT_DIR/$SCENE"
done

rm -rf $TEMP
