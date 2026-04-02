#/bin/bash
# The parameters are two directories containing views either as one animation/video file or as separate view files named as 0001.png, 0002.png...
DISTORTED=$1
REFERENCE=$2

set -xe

# Tools
# https://ffmpeg.org
FFMPEG=ffmpeg
FFPROBE=ffprobe
# https://github.com/nekhtiari/image-similarity-measures?tab=readme-ov-file
ISM=image-similarity-measures
# https://github.com/ichlubna/quiltToNative
QTN=quiltToNative/build/
# https://github.com/dingkeyan93/DISTS
DISTS=DISTS/DISTS_pytorch/

filePattern()
{
    local DIR="$(cd "$(dirname "$0")" && pwd)"
    local PATTERN=$("$DIR/guessFilePattern.sh" $1)
    echo $PATTERN
}

DISTORTED_FILES=($(ls "$DISTORTED" | sort))
REFERENCE_FILES=($(ls "$REFERENCE" | sort))
DISTORTED_COUNT=${#DISTORTED_FILES[@]}
REFERENCE_COUNT=${#REFERENCE_FILES[@]}

DISTORTED_PATTERN=""
REFERENCE_PATTERN=""
if [[ $DISTORTED_COUNT -eq 1 ]]; then
    DISTORTED_PATTERN="$DISTORTED/${DISTORTED_FILES[0]}"
else
    DISTORTED_PATTERN=$(filePattern "$DISTORTED")
fi
if [[ $REFERENCE_COUNT -eq 1 ]]; then
    REFERENCE_PATTERN="$REFERENCE/${REFERENCE_FILES[0]}"
else
    REFERENCE_PATTERN=$(filePattern "$REFERENCE")
fi

SSIM=$($FFMPEG -i $DISTORTED_PATTERN -i $REFERENCE_PATTERN -lavfi ssim -f null - 2>&1 | grep -o -P '(?<=All:).*(?= )')
PSNR=$($FFMPEG -i $DISTORTED_PATTERN -i $REFERENCE_PATTERN -lavfi psnr -f null - 2>&1 | grep -o -P '(?<=average:).*(?= min)')
VMAF=$($FFMPEG -i $DISTORTED_PATTERN -i $REFERENCE_PATTERN -filter_complex libvmaf -f null - 2>&1 | grep -o -P '(?<=VMAF score: ).*(?=)')

FSIM=0
REFERENCE_FRAMES="$REFERENCE/frames"
mkdir -p $REFERENCE_FRAMES
$FFMPEG -i $REFERENCE_PATTERN -vsync 0 "$REFERENCE_FRAMES/%04d.png"
DISTORTED_FRAMES="$DISTORTED/frames"
mkdir -p $DISTORTED_FRAMES 
$FFMPEG -i $DISTORTED_PATTERN -vsync 0 "$DISTORTED_FRAMES/%04d.png"
FRAMES_COUNT=$(ls -1q $REFERENCE_FRAMES | wc -l)

for I in $(seq 1 $(($FRAMES_COUNT))); do
    FILE=$(printf "%04d.png" "$I")
    CURRENT_FSIM=$($ISM --org_img_path=$REFERENCE_FRAMES/$FILE --pred_img_path=$DISTORTED_FRAMES/$FILE --metric fsim | tail -n 1 | jq -r '.metrics.fsim')
    FSIM=$(echo "scale=5; $FSIM + $CURRENT_FSIM" | bc)
done
FSIM=$(echo "scale=5; $FSIM / $DISTORTED_COUNT" | bc)

QUILT_REF=$REFERENCE/quilt
QUILT_DIST=$DISTORTED/quilt
mkdir -p $QUILT_REF $QUILT_DIST
cd $QTN
LKG_PORTRAIT="-width 3840 -height 2160 -pitch 246.867 -tilt -0.185828 -center 0.350117 -viewPortion 1 -subp 0.000217014"
LKG_LANDSCAPE="-width 2560 -height 1600 -pitch 354.677 -tilt -0.113949 -center 0.042 -viewPortion 0.99976 -subp 0.000130208"
LKG=$LKG_PORTRAIT
WIDTH=$($FFPROBE -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$REFERENCE/${REFERENCE_FILES[0]}") 
HEIGHT=$($FFPROBE -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$REFERENCE/${REFERENCE_FILES[0]}") 
if [[ $WIDTH > $HEIGHT ]]; then
    LKG=$LKG_LANDSCAPE
fi
./QuiltToNative -i $DISTORTED_FRAMES -o $QUILT_DIST -cols $FRAMES_COUNT -rows 1 -focus 0 $LKG
./QuiltToNative -i $REFERENCE_FRAMES -o $QUILT_REF -cols $FRAMES_COUNT -rows 1 -focus 0 $LKG
cd - > /dev/null 
cd $DISTS
NAT_DISTS=$(python DISTS_pt.py --dist "$QUILT_DIST/output.png" --ref "$QUILT_REF/output.png" 2>/dev/null)
cd - > /dev/null 

rm -rf $DISTORTED_FRAMES $REFERENCE_FRAMES $QUILT_DIST $QUILT_REF
echo $SSIM,$PSNR,$VMAF,$FSIM,$NAT_DISTS
