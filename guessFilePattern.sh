#!/bin/bash
set -e

guessFilePattern() 
{
    local FILES=("$1"/*)
    if [[ -e ${FILES[0]} && ! -e ${FILES[1]} && -f ${FILES[0]} ]]; then
      printf '%s\n' "${FILES[0]}"
    else
        local DIR="$1"
        local FILE=$(find "$DIR" -maxdepth 1 -type f | sort | grep -E '[0-9]+' | head -n1)
        local EXT="${FILE##*.}"
        local NUM=$(basename "$FILE" | grep -o '[0-9]\+')
        local LEN=${#NUM}
        BASE=$(basename "$FILE")
        PATTERN=$(echo "$BASE" | sed "s/$NUM/%0${LEN}d/")
        echo "$DIR/$PATTERN"
    fi
}

guessFilePattern $1
