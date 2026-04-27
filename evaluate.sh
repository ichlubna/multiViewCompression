#!/bin/bash

#Docker must be running
# sudo systemctl start docker

# Parameters
# The directory contains subirectories with the views, one subdirectory per scene, the views should be named as 0001.png, 0002.png...
INPUT_DIR=$1
# Path to the csv files with the results
OUTPUT_DIR=$2

# Set paths to the external tools used
# Binaries:
# https://ffmpeg.org
FFMPEG=ffmpeg
FFPROBE=ffprobe
# https://github.com/libjxl/libjxl
JXL_ENCODER=cjxl
JXL_DECODER=djxl
# https://github.com/fraunhoferhhi/vvenc
VVENC=vvenc/bin/release-static/vvencapp
# https://github.com/fraunhoferhhi/vvdec
VVDEC=vvdec/bin/release-static/vvdecapp
# https://gitlab.com/AOMediaCodec/avm
AVMENC=avm/build/avmenc
AVMDEC=avm/build/avmdec
# Paths
# https://github.com/bbldcver/EDEN
# Conda setup needs to be prepared for the following tools according to each repository README 
EDEN=EDEN
# https://github.com/KAIST-VICLab/BiM-VFI
BIMVFI=BIMVFI
# https://gitlab.com/wg1/jpeg-ai/jpeg-ai-reference-software
JPEGAI=jpgai
# https://github.com/microsoft/DCVC/
# Edited with: https://github.com/microsoft/DCVC/issues/85
DCVC=DCVC
# https://github.com/Austin4USTC/DCMVC
# Edited with: https://github.com/Austin4USTC/DCMVC/issues/5
# Added custom ppm export
DCMVC=DCMVC
# https://github.com/jzyustc/GLC
GLC=GLC

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

HEADER="scene, quality, compression, SSIM, PSNR, VMAF, FSIM, NAT_DISTS, LIQE, QUALICLIP, ARNIQA, encode time, decode time, size"
for KEY in "${!LOG[@]}"; do
    >${LOG[$KEY]}
    echo $HEADER >> ${LOG[$KEY]}
done
HEADER="scene, quality, compression, SSIM, PSNR, VMAF, FSIM, NAT_DISTS, LIQE, QUALICLIP, ARNIQA, interpolation time, interpolation method, size"
>${LOG['multiInterpolatedHalf']}
echo $HEADER >> ${LOG['multiInterpolatedHalf']}
>${LOG['multiInterpolatedFull']}
echo $HEADER >> ${LOG['multiInterpolatedFull']}

SCENES=($(ls "$INPUT_DIR" | sort))
TEMP=$(mktemp -d)

codecQuality() 
{
    local Q=$(echo "scale=5; $1*$2" | bc)
    local Q=$(printf "%.0f" "$Q")
    echo $Q
}

codecQualityInverse() 
{
    local Q=$(echo "scale=5; (1.0-$1)*$2" | bc)
    local Q=$(printf "%.0f" "$Q")
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

clearDirs()
{
    for DIR in "$@"; do
        mkdir -p "$DIR"
        if [ -n "$DIR" ] && [ -e "$DIR" ] && [ "$DIR" != "/" ]; then
            rm -rf "$DIR"/*
        fi
    done
}

encode()
{
    local METHOD=$1
    local INPUT=$2
    local QUALITY=$3
    local OUTPUT=$4
    local PATTERN=$(filePattern "$INPUT")
    local WIDTH=$($FFPROBE -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$PATTERN")
    local HEIGHT=$($FFPROBE -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$PATTERN")
    local FRAMES=$($FFPROBE -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nokey=1:noprint_wrappers=1 "$PATTERN")
    
    if [ $METHOD == "jxl" ]; then 
        local INPUT_FILE="$TEMP/reference.apng"
        local OUTPUT_FILE="$OUTPUT/encoded.jxl"
        "$FFMPEG" -y -i "$PATTERN" "$INPUT_FILE"
        local MAX_Q=99 
        local Q=$(codecQuality $QUALITY $MAX_Q)
        local START=$(now)
        "$JXL_ENCODER" "$INPUT_FILE" "$OUTPUT_FILE" -q $Q --lossless_jpeg=0 >&2
        local END=$(now)
    elif [ $METHOD == "vvc" ]; then
        local INPUT_FILE="$TEMP/reference.y4m"
        $FFMPEG -y -i "$PATTERN" -pix_fmt yuv420p "$INPUT_FILE"
        local OUTPUT_FILE="$OUTPUT/encoded.266"
        local MAX_Q=63 
        local Q=$(codecQualityInverse $QUALITY $MAX_Q)
        local START=$(now)
        "$VVENC" -i "$INPUT_FILE" -q $Q -o "$OUTPUT_FILE" >&2
        local END=$(now) 
    elif [ $METHOD == "jpegai" ]; then
        local INPUT_DIR="input"
        local OUTPUT_DIR="encoded"
        clearDirs "$JPEGAI/$INPUT_DIR" "$JPEGAI/$OUTPUT_DIR"
        cp -r "$INPUT/." "$JPEGAI/$INPUT_DIR"
        cd $JPEGAI
        local START=$(now)
        for FILE in $(ls "$INPUT_DIR" | sort); do
            local INPUT_FILE="$INPUT_DIR/$FILE"
            local OUTPUT_FILE="$OUTPUT_DIR/$FILE"
            echo $WIDTH"x"$HEIGHT > $TEMP/resolution.txt
            local SIZE=$(stat -c%s "$INPUT_FILE")
            local BITS=$((SIZE * 8))
            local BPP_ORIG=$(awk "BEGIN {print $BITS / ($WIDTH * $HEIGHT)}")
            #local Q=$(echo "scale=5; e(l(2) * -6 * (1 - $QUALITY))" | bc -l)
            local Q=$(echo "scale=5;
              raw = e(l(2) * -6 * (1 - $QUALITY));
              min = e(l(2) * -6 * 1);
              max = e(l(2) * -6 * 0);
              (raw - min) / (max - min)
            " | bc -l)
            local BPP_TARGET=$(codecQuality $Q $BPP_ORIG)
            local BPP_TARGET=$(awk "BEGIN {printf \"%d\",1+$BPP_TARGET*100*0.5}")
            docker run --rm --mount src=.,target=/root/vm_init,type=bind diveraak/jpeg_ai:latest bash -c "source /root/miniconda3/etc/profile.d/conda.sh && conda activate jpeg_ai_vm && python -m src.reco.coders.encoder $INPUT_FILE $OUTPUT_FILE --set_target_bpp $BPP_TARGET" >&2
        done
        cd - > /dev/null
        cp -r "$JPEGAI/$OUTPUT_DIR/." "$OUTPUT"
        local END=$(now)
    elif [ $METHOD == "av1" ]; then
        local MAX_Q=62
        local Q=$(codecQualityInverse $QUALITY $MAX_Q)
        local Q=$((1 + $Q))
        local START=$(now)
        "$FFMPEG" -i "$PATTERN" -c:v libaom-av1 -cpu-used 8 -crf $Q "$OUTPUT/encoded.mkv" >&2
        local END=$(now) 
    elif [ $METHOD == "av2" ]; then
        local INPUT_FILE="$TEMP/reference.y4m"
        $FFMPEG -y -i "$PATTERN" -pix_fmt yuv420p "$INPUT_FILE"
        local OUTPUT_FILE="$OUTPUT/encoded.av2"
        local MAX_Q=254 
        local Q=$(codecQualityInverse $QUALITY $MAX_Q)
        local START=$(now)
        "$AVMENC" "$INPUT_FILE" --qp=$Q --row-mt=1 --tile-rows=2 --tile-columns=2 --end-usage=q --cpu-used=8 --threads=8 -o "$OUTPUT_FILE" >&2
        local END=$(now) 
    elif [ $METHOD == "dcvc" ]; then 
        local MAX_Q=63
        local Q=$(codecQuality $QUALITY $MAX_Q)
        echo $WIDTH"x"$HEIGHT > $TEMP/resolution.txt
        echo $FRAMES > $TEMP/count.txt
        clearDirs "$DCVC/test" "$DCVC/test/test" "$DCVC/output"
        $FFMPEG -i "$PATTERN" -pix_fmt rgb24 "$DCVC/test/test/im%05d.png"
        cd $DCVC
        echo "{" > dataset.json
        echo "\"root_path\": \"$(pwd $DCVC)\"," >> dataset.json
        echo "\"test_classes\": {" >> dataset.json
        echo "\"\": {" >> dataset.json
        echo "\"test\": 1," >> dataset.json
        echo "\"base_path\": \"test\"," >> dataset.json
        echo "\"src_type\": \"png\"," >> dataset.json
        echo "\"sequences\": {" >> dataset.json
        echo "\"test\": {\"width\": $WIDTH, \"height\": $HEIGHT, \"frames\": $FRAMES, \"intra_period\": 9999}" >> dataset.json
        echo "}" >> dataset.json
        echo "}" >> dataset.json
        echo "}" >> dataset.json
        echo "}" >> dataset.json
        local LOG=$(conda run -n dcvc python test_video.py --model_path_i ./checkpoints/cvpr2024_image.pth.tar --model_path_p ./checkpoints/cvpr2024_video.pth.tar --rate_num 2 --test_config ./dataset.json --cuda 1 --worker 1 --output_path output.json --force_intra_period 9999 --write_stream 1 --save_decoded_frame 1 --stream_path output --verbose 1 --q_indexes_i $Q $Q)
        read ENCODE_TIME DECODE_TIME < <(echo "$LOG" | grep "average encoding time" | tail -n 1 | sed -E 's/.*encoding time ([0-9]+) ms, average decoding time ([0-9]+) ms.*/\1 \2/')
        local ENCODE_TIME=$(echo "$ENCODE_TIME * $FRAMES" | bc)
        local DECODE_TIME=$(echo "$DECODE_TIME * $FRAMES" | bc)
        local AVE_ALL_FRAME_BPP=$(grep -o '"ave_all_frame_bpp":[^,]*' "output/test_q$Q.json" | cut -d: -f2)
        local PIXEL_NUM=$(grep -o '"frame_pixel_num":[^,]*' "output/test_q$Q.json" | cut -d: -f2)
        local SIZE=$(echo "$AVE_ALL_FRAME_BPP * $PIXEL_NUM * $FRAMES" | bc)
        local SIZE=$(printf "%.0f\n" "$SIZE")
        truncate -s $SIZE "$OUTPUT/placeholder.bin"
        cd - > /dev/null
    elif [ $METHOD == "dcmvc" ]; then 
        local MAX_Q=63
        local Q=$(codecQuality $QUALITY $MAX_Q)
        echo $WIDTH"x"$HEIGHT > $TEMP/resolution.txt
        echo $FRAMES > $TEMP/count.txt
        clearDirs "$DCMVC/test" "$DCMVC/test/test" "$DCMVC/output" "$DCMVC/decoded_frames"
        $FFMPEG -i "$PATTERN" -pix_fmt rgb24 "$DCMVC/test/test/im%05d.png"
        cd $DCMVC
        echo "{" > dataset.json
        echo "\"root_path\": \"$(pwd $DCMVC)\"," >> dataset.json
        echo "\"test_classes\": {" >> dataset.json
        echo "\"\": {" >> dataset.json
        echo "\"test\": 1," >> dataset.json
        echo "\"base_path\": \"test\"," >> dataset.json
        echo "\"src_type\": \"png\"," >> dataset.json
        echo "\"sequences\": {" >> dataset.json
        echo "\"test\": {\"width\": $WIDTH, \"height\": $HEIGHT, \"frames\": $FRAMES, \"gop\": 9999}" >> dataset.json
        echo "}" >> dataset.json
        echo "}" >> dataset.json
        echo "}" >> dataset.json
        echo "}" >> dataset.json
        local LOG=$(conda run -n DCMVC python test_video.py --i_frame_model_path ./checkpoints/cvpr2023_image_psnr.pth.tar --p_frame_model_path ./checkpoints/dcmvc_p_frame.pth.tar --rate_num 2 --test_config ./dataset.json --cuda 1 --worker 1 --output_path output.json --force_intra_period 9999 --write_stream 1 --save_decoded_frame 1 --stream_path output --verbose 2 --i_frame_q_indexes $Q $Q --p_frame_q_indexes $Q $Q 2>&1)
        TIME=$(awk '
        match($0, /([0-9]+(\.[0-9]+)?) seconds/, m) {
            sum += m[1]; count++
        }
        END {
            print (count ? (sum / count) * 1000 : 0)
        }
        ' <<< "$LOG")
        local ENCODE_TIME=$(echo "$TIME * 0.6" | bc)
        local DECODE_TIME=$(echo "$TIME * 0.4" | bc)
        local AVE_ALL_FRAME_BPP=$(jq -r '."".test."000".ave_all_frame_bpp' output.json)
        local PIXEL_NUM=$(jq -r '."".test."000".frame_pixel_num' output.json)
        local SIZE=$(echo "$AVE_ALL_FRAME_BPP * $PIXEL_NUM * $FRAMES" | bc)
        local SIZE=$(printf "%.0f\n" "$SIZE")
        truncate -s $SIZE "$OUTPUT/placeholder.bin"
        cd - > /dev/null
    elif [ $METHOD == "glc" ]; then 
        local MAX_Q=63
        local Q=$(codecQuality $QUALITY $MAX_Q)
        echo $WIDTH"x"$HEIGHT > $TEMP/resolution.txt
        echo $FRAMES > $TEMP/count.txt
        clearDirs "$GLC/test" "$GLC/test/test" "$GLC/output"
        $FFMPEG -i "$PATTERN" -pix_fmt rgb24 "$GLC/test/test/im%05d.png"
        cd $GLC
        echo "{" > dataset.json
        echo "\"root_path\": \"$(pwd $GLC)\"," >> dataset.json
        echo "\"test_classes\": {" >> dataset.json
        echo "\"\": {" >> dataset.json
        echo "\"test\": 1," >> dataset.json
        echo "\"base_path\": \"test\"," >> dataset.json
        echo "\"src_type\": \"png\"," >> dataset.json
        echo "\"sequences\": {" >> dataset.json
        echo "\"test\": {\"width\": $WIDTH, \"height\": $HEIGHT, \"frames\": $FRAMES, \"intra_period\": 9999}" >> dataset.json
        echo "}" >> dataset.json
        echo "}" >> dataset.json
        echo "}" >> dataset.json
        echo "}" >> dataset.json
        local LOG=$(python test_video.py --rate_num 1 --test_config dataset.json --cuda 1 --cuda_idx 0 -w 1 --save_decoded_frame 1 --stream_path ./output --output_path ./output.json --model_path_i ./checkpoints/GLC_image.pth.tar --model_path_p ./checkpoints/GLC_Video.pth.tar --verbose 2 --q_indexes_i $Q --q_indexes_p $Q)
        TIME=$(awk '
        {
            while (match($0, /([0-9]+(\.[0-9]+)?) ms/, m)) {
                sum += m[1]
                count++
                $0 = substr($0, RSTART + RLENGTH)
            }
        }
        END {
            if (count) print sum / count
            else print 0
        }
        ' <<< "$LOG")
        local ENCODE_TIME=$(echo "$TIME * 0.6" | bc)
        local DECODE_TIME=$(echo "$TIME * 0.4" | bc) 
        local AVE_ALL_FRAME_BPP=$(grep -o '"ave_all_frame_bpp":[^,]*' "output/test_q$Q.json" | cut -d: -f2)
        local PIXEL_NUM=$(grep -o '"frame_pixel_num":[^,]*' "output/test_q$Q.json" | cut -d: -f2)
        local SIZE=$(echo "$AVE_ALL_FRAME_BPP * $PIXEL_NUM * $FRAMES" | bc)
        local SIZE=$(printf "%.0f\n" "$SIZE")
        truncate -s $SIZE "$OUTPUT/placeholder.bin"
        cd - > /dev/null
    else
        echo "Unsupported codec: $METHOD"
    fi
    if [[ -v START && -v END ]]; then
        echo $(elapsed $START $END)
    else
        echo $ENCODE_TIME
        echo $DECODE_TIME > $TEMP/decodeTime.txt
    fi
}

decode()
{
    local METHOD=$1
    local INPUT=$2
    local OUTPUT=$3
    local FILES=($(ls "$INPUT" | sort))
    if [ $METHOD == "jxl" ]; then 
        local START=$(now)
        "$JXL_DECODER" "$INPUT/${FILES[0]}" "$OUTPUT/decoded.apng" >&2
        local END=$(now)
    elif [ $METHOD == "vvc" ]; then
        local START=$(now)
        "$VVDEC" -b "$INPUT/${FILES[0]}" -o "$OUTPUT/decoded.y4m" >&2
        local END=$(now)
    elif [ $METHOD == "jpegai" ]; then
        local INPUT_DIR="encoded"
        local OUTPUT_DIR="decoded"
        clearDirs "$JPEGAI/$OUTPUT_DIR"
        cd $JPEGAI
        local START=$(now)
        for FILE in $(ls "$INPUT_DIR" | sort); do
            local INPUT_FILE="$INPUT_DIR/$FILE"
            local BASE="${FILE%.*}"
            local OUTPUT_FILE="$OUTPUT_DIR/$BASE.yuv"
            docker run --rm --mount src=.,target=/root/vm_init,type=bind diveraak/jpeg_ai:latest bash -c "source /root/miniconda3/etc/profile.d/conda.sh && conda activate jpeg_ai_vm && python -m src.reco.coders.decoder $INPUT_FILE $OUTPUT_FILE" >&2
            local RES=$(cat $TEMP"/resolution.txt")
            $FFMPEG -f rawvideo -pix_fmt yuv444p -color_range pc -colorspace bt709 -color_trc bt709 -color_primaries bt709 -video_size $RES -i $OUTPUT_FILE $OUTPUT_DIR/$BASE.png
            rm -f $OUTPUT_FILE
        done
        cd - > /dev/null
        cp -r "$JPEGAI/$OUTPUT_DIR/." "$OUTPUT"
        local END=$(now)
    elif [ $METHOD == "av1" ]; then
        local START=$(now)
        "$FFMPEG" -i "$INPUT/${FILES[0]}" "$OUTPUT/%04d.png" >&2
        local END=$(now)
    elif [ $METHOD == "av2" ]; then
        local START=$(now)
        "$AVMDEC" "$INPUT/${FILES[0]}" -o "$OUTPUT/decoded.y4m" >&2
        local END=$(now)
    elif [ $METHOD == "dcvc" ]; then
        local RES=$(cat $TEMP"/resolution.txt")
        local COUNT=$(cat $TEMP"/count.txt")
        local ID=0
        for FILE in $DCVC/*.yuv; do 
            local NAME=$(basename "$FILE")
            local NAME="${NAME%.*}"
            $FFMPEG -y -f rawvideo -pix_fmt yuv444p -color_range pc -colorspace bt709 -color_trc bt709 -color_primaries bt709 -video_size $RES -i $FILE "$OUTPUT/$NAME.png" >&2
            ID=$((ID + 1))
            if [ $ID -ge $COUNT ]; then
                break
            fi
        done
    elif [ $METHOD == "dcmvc" ]; then
        local RES=$(cat $TEMP"/resolution.txt")
        local COUNT=$(cat $TEMP"/count.txt")
        local ID=0
        local OUT_PATH=$(find "$DCMVC/output/" -type f -name '*.ppm' -print -quit | xargs -r dirname)
        $FFMPEG -y -i "$OUT_PATH/%03d.ppm" -pix_fmt rgb24 "$OUTPUT/%04d.png" >&2
    elif [ $METHOD == "glc" ]; then
        local RES=$(cat $TEMP"/resolution.txt")
        local COUNT=$(cat $TEMP"/count.txt")
        local ID=0
        local OUT_PATH=$(find "$GLC/output/" -type f -name '*.png' -print -quit | xargs -r dirname)
        $FFMPEG -y -i "$OUT_PATH/im%05d.png" -pix_fmt rgb24 "$OUTPUT/%04d.png" >&2
    else
        echo "Unsupported codec: $METHOD"
    fi
    if [[ -v START && -v END ]]; then
        echo $(elapsed $START $END)
    else
        echo $(cat "$TEMP/decodeTime.txt")
    fi
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
        conda run -n eden CUDA_VISIBLE_DEVICES=0 python inference.py --frame_0_path $FIRST --frame_1_path $SECOND --interpolated_results_dir $RESULT_DIR >&2 
        local END=$(now)
        $FFMPEG -y -i "$RESULT_DIR/interpolated.png" -pix_fmt rgb24 $OUTPUT
        cd - > /dev/null
    else
        cp $FIRST $INTER_INPUT_PATH_SCENE
        cp $SECOND $INTER_INPUT_PATH_SCENE
        cd $BIMVFI
        local START=$(now)
        conda run -n bimvfi python main.py --cfg cfgs/bim_vfi_demo.yaml >&2
        $FFMPEG -y -i "save/bim_vfi_original/output/demo/scene/0000001.jpg" -pix_fmt rgb24 $OUTPUT
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
    $FFMPEG -i "$PATTERN" -pix_fmt rgb24 "$IN_DIR/%04d.png"
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
    $FFMPEG -y -i "$PATTERN" -pix_fmt rgb24 "$SCENE/%04d.png"

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
    
    #for KEY in single stereoClose stereoFar multi; do
    for KEY in single; do
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
    #for METHOD in jxl jpegai vvc av1 av2 dcvc dcmvc glc; do
    for METHOD in glc; do
        #for QUALITY in $(seq 0.0 0.1 1.0); do
        for QUALITY in 1.0; do
            evaluate $METHOD "$SCENE" $QUALITY
        done
    done
}

for SCENE in $SCENES; do
    measure "$INPUT_DIR/$SCENE"
done

rm -rf $TEMP
tail -n +1 "$OUTPUT_DIR"/*
