#!/bin/bash

read -p "Enter variable prefix (e.g., userid): " VAR_NAME
read -p "Starting Major Version (e.g., 1): " MAJOR_V
read -p "Enter path to functions file: " FILE_PATH
read -p "Shuffle variables? (y/n): " DO_SHUFFLE
read -p "Use [M]D5 (fixed 32) or [R]andom lengths? (m/r): " MODE_CHOICE

if [[ ! -f "$FILE_PATH" ]]; then echo "File not found!"; exit 1; fi

# 2. Hex Encode
ENCODED=$(cat "$FILE_PATH" | od -A n -t x1 | tr -d ' \n')
TOTAL_LEN=${#ENCODED}

# 3. Generate Chunks with Rollover & Padding Logic
declare -a CHUNKS
CURRENT_POS=0
MINOR_V=0
V_COUNT=0

# Determine standard size for padding reference
[[ "$MODE_CHOICE" =~ ^[Rr]$ ]] && PAD_SIZE=40 || PAD_SIZE=32

while [ $CURRENT_POS -lt $TOTAL_LEN ]; do
    if [[ "$MODE_CHOICE" =~ ^[Rr]$ ]]; then
        # Random variance (e.g., 20 to 44 characters)
        CHUNK_SIZE=$(( (RANDOM % 13 + 10) * 2 ))
    else
        # Strict MD5 Length
        CHUNK_SIZE=32
    fi

    CHUNK="${ENCODED:$CURRENT_POS:$CHUNK_SIZE}"
    [ -z "$CHUNK" ] && break

    # Padding logic for the very last chunk so it matches visually
    if [ $((CURRENT_POS + CHUNK_SIZE)) -ge $TOTAL_LEN ]; then
        while [ ${#CHUNK} -lt $PAD_SIZE ]; do
            CHUNK="${CHUNK}0"
        done
    fi

    # Format decimal with underscore for Bash compliance
    V_STR=$(printf "%d_%02d" "$MAJOR_V" "$MINOR_V")
    CHUNKS+=("${VAR_NAME}_ver${V_STR}=\"${CHUNK}\"")

    # Increment and Rollover (v1_99 -> v2_00)
    ((MINOR_V++))
    ((V_COUNT++))
    if [ $MINOR_V -ge 100 ]; then
        MINOR_V=0
        ((MAJOR_V++))
    fi

    CURRENT_POS=$(( CURRENT_POS + CHUNK_SIZE ))
done

# 4. Output Variables
echo -e "\n# ---- Paste into script ----"
if [[ "$DO_SHUFFLE" =~ ^[Yy]$ ]]; then
    printf "%s\n" "${CHUNKS[@]}" | shuf
else
    printf "%s\n" "${CHUNKS[@]}"
fi

# 5. Final Summary and Loaders Menu
echo -e "\n# ---- Loaders (Updated for Underscore) ----"
echo "eval \"\$(compgen -v ${VAR_NAME} | sort -V | while read _v; do printf \"\${!_v}\"; done | perl -lne 'print pack(\"H*\",\$_)')\" 2>/dev/null"
echo "OR"
echo "if [ \"\$UID\" -ge 0 ]; then . <(compgen -v ${VAR_NAME} | sort -V | while read _i; do printf \"\${!_i}\"; done | xxd -r -p) 2>/dev/null; fi"
echo ""
echo "# -------------------------------------------"
echo "# Total Vars    : $V_COUNT  |  Hex length: $TOTAL_LEN"
echo "# Chunks        : Padding applied to last chunk ($PAD_SIZE chars)"
echo "# Command to undo for testing:"
echo "# for i in \$(compgen -v ${VAR_NAME}); do unset \$i; done"
echo "# -------------------------------------------"

