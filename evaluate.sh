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
HEADER="scene, quality, compression, SSIM, PSNR, VMAF, FSIM, NAT_DISTS, interpolation time, interpolation method, size"
>${LOG['multiInterpolatedHalf']}
echo $HEADER >> ${LOG['multiInterpolatedHalf']}
>${LOG['multiInterpolatedFull']}
echo $HEADER >> ${LOG['multiInterpolatedFull']}

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
    for DIR in "$@"; do
        mkdir -p "$DIR"
        rm -f "$DIR"/*
    done
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

interpolateFrames()
{
    local FIRST=$1
    local SECOND=$2
    local OUTPUT=$3
    local METHOD=$4

    local RESULT_DIR=$TEMP/interpolated
    mkdir -p $RESULT_DIR 

    cd $BIMVFI
    local INTER_INPUT_PATH="$TEMP/interpolateInput"
    local INTER_INPUT_PATH_SCENE="$TEMP/interpolateInput/scene"
    mkdir -p $INTER_INPUT_PATH
    clearDirs "$INTER_INPUT_PATH_SCENE" 
    sed -i "s|^\(\s*root_path:\s*\).*|\1$INTER_INPUT_PATH|" cfgs/bim_vfi_demo.yaml
    sed -i "s|inference_demo(self.model, 8, video_path, out_path)|inference_demo(self.model, 2, video_path, out_path)|" modules/models/base_model.py
    cd - > /dev/null

    if [ $METHOD == "eden" ]; then 
        cd $EDEN
        local START=$(now)
        conda run -n eden CUDA_VISIBLE_DEVICES=0 python inference.py --frame_0_path $FIRST --frame_1_path $SECOND --interpolated_results_dir $RESULT_DIR &> /dev/null 
        local END=$(now)
        cp "$RESULT_DIR/interpolated.png" $OUTPUT
        cd - > /dev/null
    else
        cp $FIRST $INTER_INPUT_PATH_SCENE
        cp $SECOND $INTER_INPUT_PATH_SCENE
        cd $BIMVFI
        local START=$(now)
        conda run -n bimvfi python main.py --cfg cfgs/bim_vfi_demo.yaml &> /dev/null
        cp "save/bim_vfi_original/output/demo/scene/0000001.jpg" $OUTPUT
        local END=$(now)
        cd - > /dev/null
    fi
    echo $(elapsed $START $END)
}

interpolate()
{
    local INPUT=$1
    local INTERPOLATED_DIR_HALF=$2
    local INTERPOLATED_DIR_FULL=$3
    local METHOD=$4

    local PATTERN=$(filePattern "$INPUT")
    local IN_DIR="$TEMP/toInterpolate"
    clearDirs "$IN_DIR"
    $FFMPEG -i "$PATTERN" "$IN_DIR/%04d.png"
    mapfile -t IN_FILES < <(find "$IN_DIR" -maxdepth 1 -type f | sort) 
    local COUNT=${#IN_FILES[@]}
   
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
    local FIRST_FILE=$(fileName "${IN_FILES[0]}" 1)
    cp "${IN_FILES[0]}" "$INTERPOLATED_DIR_HALF/$FIRST_FILE" 
    cp "${IN_FILES[0]}" "$INTERPOLATED_DIR_FULL/$FIRST_FILE" 
  
    local PAIRS=("$INTERPOLATED_DIR_FULL/$FIRST_FILE $INTERPOLATED_DIR_FULL/$LAST_FILE")
    local FINISHED=$(($FINISHED + 2))
    local TOTAL_TIME=0
    local INTERPOLATED_COUNT=0
    while (( FINISHED < $COUNT )); do
        local NEW_PAIRS=()
        for PAIR in "${PAIRS[@]}"; do
            read -r FIRST SECOND <<< "$PAIR"
            local FIRST_ID=$( fileToNumber "$FIRST")
            local SECOND_ID=$( fileToNumber "$SECOND")
            local NEW_ID=$((($FIRST_ID + $SECOND_ID) / 2))
            
            local NEW="$INTERPOLATED_DIR_FULL/"$(fileName "interpolated.png" $NEW_ID)
            local TIME=$(interpolateFrames $FIRST $SECOND $NEW $METHOD)
            local TOTAL_TIME=$(echo "scale=5; $TOTAL_TIME + $TIME" | bc)
            local INTERPOLATED_COUNT=$(($INTERPOLATED_COUNT + 1))

            local NEW_PAIRS+=("$FIRST $INTERPOLATED_DIR_FULL/$NEW")
            local NEW_PAIRS+=("$INTERPOLATED_DIR_FULL/$NEW $SECOND")
            local FINISHED=$(($FINISHED + 1))
        done
        local PAIRS=("${NEW_PAIRS[@]}")
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
        local NEW_INTER=$(fileName "interpolated.png" $(($FIRST_ID + 1)))
        local NEW="$INTERPOLATED_DIR_HALF/$NEW_INTER"
        local TIME=$(interpolateFrames $FIRST $SECOND $NEW $METHOD)
        local TOTAL_TIME=$(echo "scale=5; $TOTAL_TIME + $TIME" | bc)
        local INTERPOLATED_COUNT=$(($INTERPOLATED_COUNT + 1))
        cd - > /dev/null 
    done 

    local TOTAL_TIME=$(echo "scale=5; $TOTAL_TIME / $INTERPOLATED_COUNT" | bc)
    echo $TOTAL_TIME 
}

evaluate()
{
    local METHOD=$1
    local INPUT_SCENE=$2
    local QUALITY=$3

    SCENE_NAME=$(basename "$INPUT_SCENE")
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
    local INTERPOLATED_HALF_BIMVFI="$TEMP/interpolatedHalfBIMVFI"
    local INTERPOLATED_FULL_BIMVFI="$TEMP/interpolatedFullBIMVFI"
    
    for KEY in single stereoClose stereoFar multi; do
    #for KEY in multi; do
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
        echo $SCENE_NAME, $QUALITY, $METHOD, $METRICS, $ENCODE_TIME, $DECODE_TIME, $SIZE  >> ${LOG["$KEY"]} 
        if [ $KEY == "multi" ]; then
            local INTERPOLATION_TIME=$(interpolate "$DECODED" "$INTERPOLATED_HALF_EDEN" "$INTERPOLATED_FULL_EDEN" "eden")
            local METRICS=$(quality "$REFERENCE" "$INTERPOLATED_HALF_EDEN")
            local SIZE_HALF=$(echo "scale=2; $SIZE * 0.5" | bc) 
            echo $SCENE_NAME, $QUALITY, $METHOD, $METRICS, $INTERPOLATION_TIME, eden, $SIZE_HALF  >> ${LOG["multiInterpolatedHalf"]} 
            local METRICS=$(quality "$REFERENCE" "$INTERPOLATED_FULL_EDEN")
            local SIZE_FULL=$(echo "scale=2; $SIZE / $COUNT * 2" | bc)
            echo $SCENE_NAME, $QUALITY, $METHOD, $METRICS, $INTERPOLATION_TIME, eden, $SIZE_FULL  >> ${LOG["multiInterpolatedFull"]} 
            local INTERPOLATION_TIME=$(interpolate "$DECODED" "$INTERPOLATED_HALF_BIMVFI" "$INTERPOLATED_FULL_BIMVFI" "bimvfi")
            local METRICS=$(quality "$REFERENCE" "$INTERPOLATED_HALF_BIMVFI")
            echo $SCENE_NAME, $QUALITY, $METHOD, $METRICS, $INTERPOLATION_TIME, bimvfi, $SIZE_HALF  >> ${LOG["multiInterpolatedHalf"]} 
            local METRICS=$(quality "$REFERENCE" "$INTERPOLATED_FULL_BIMVFI")
            echo $SCENE_NAME, $QUALITY, $METHOD, $METRICS, $INTERPOLATION_TIME, bimvfi, $SIZE_FULL  >> ${LOG["multiInterpolatedFull"]} 
        fi
    done
}

measure()
{
    local SCENE=$1
    local METHODS=("jxl")
    for METHOD in "${METHODS[@]}"; do
        #for QUALITY in $(seq 0.0 0.1 0.05); do
        for QUALITY in 0.5; do
            evaluate $METHOD "$SCENE" $QUALITY
        done
    done
}

for SCENE in $SCENES; do
    measure "$INPUT_DIR/$SCENE"
done

rm -rf $TEM
