#/bin/bash
# The parameters are two directories containing views either as one animation/video file or as separate view files named as 0001.png, 0002.png...
DISTORTED=$1
REFERENCE=$2

# Tools
# https://ffmpeg.org
FFMPEG=ffmpeg

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

echo $SSIM,$PSNR,$VMAF
