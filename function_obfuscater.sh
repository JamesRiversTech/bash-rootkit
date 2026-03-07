#!/bin/bash

VAR_NAME="$1"
MAJOR_V="$2"
FILE_PATH="$3"
DO_SHUFFLE="$4"
MODE_CHOICE="$5"
LOADER="$6"

if [[ -z "$VAR_NAME" || -z "$MAJOR_V" || -z "$FILE_PATH" || -z "$DO_SHUFFLE" || -z "$MODE_CHOICE" || -z "$LOADER" ]]; then
    echo "Usage: $0 <var_prefix> <major_version> <file_path> <shuffle y/n> <mode m/r> <loader 1/2>"
    exit 1
fi

if [[ ! -f "$FILE_PATH" ]]; then
    echo "File not found: $FILE_PATH"
    exit 1
fi

ENCODED=$(cat "$FILE_PATH" | od -A n -t x1 | tr -d ' \n')
TOTAL_LEN=${#ENCODED}

declare -a CHUNKS
CURRENT_POS=0
MINOR_V=0
V_COUNT=0

[[ "$MODE_CHOICE" =~ ^[Rr]$ ]] && PAD_SIZE=40 || PAD_SIZE=32

while [ $CURRENT_POS -lt $TOTAL_LEN ]; do
    if [[ "$MODE_CHOICE" =~ ^[Rr]$ ]]; then
        CHUNK_SIZE=$(( (RANDOM % 13 + 10) * 2 ))
    else
        CHUNK_SIZE=32
    fi

    CHUNK="${ENCODED:$CURRENT_POS:$CHUNK_SIZE}"
    [ -z "$CHUNK" ] && break

    if [ $((CURRENT_POS + CHUNK_SIZE)) -ge $TOTAL_LEN ]; then
        while [ ${#CHUNK} -lt $PAD_SIZE ]; do
            CHUNK="${CHUNK}0"
        done
    fi

    V_STR=$(printf "%d_%02d" "$MAJOR_V" "$MINOR_V")
    CHUNKS+=("${VAR_NAME}_ver${V_STR}=\"${CHUNK}\"")

    ((MINOR_V++))
    ((V_COUNT++))
    if [ $MINOR_V -ge 100 ]; then
        MINOR_V=0
        ((MAJOR_V++))
    fi

    CURRENT_POS=$(( CURRENT_POS + CHUNK_SIZE ))
done

if [[ "$DO_SHUFFLE" =~ ^[Yy]$ ]]; then
    printf "%s\n" "${CHUNKS[@]}" | shuf
else
    printf "%s\n" "${CHUNKS[@]}"
fi

if [[ "$LOADER" == "1" ]]; then
    echo "eval \"\$(compgen -v ${VAR_NAME} | sort -V | while read _v; do printf \"\${!_v}\"; done | perl -lne 'print pack(\"H*\",\$_)')\" 2>/dev/null"
else
    echo "if [ \"\$UID\" -ge 0 ]; then . <(compgen -v ${VAR_NAME} | sort -V | while read _i; do printf \"\${!_i}\"; done | xxd -r -p) 2>/dev/null; fi"
fi
