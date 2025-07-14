#!/bin/bash

# Cek input
if [[ -z "$1" ]]; then
    echo "Usage: $0 <domain_or_url> [--limit=10000] [--matchType=prefix] [--collapse=urlkey]"
    exit 1
fi

INPUT="$1"
shift

# Default parameter
LIMIT="10000"
MATCH_TYPE="prefix"
COLLAPSE="urlkey"

# Parse argumen tambahan
for arg in "$@"; do
    case "$arg" in
        --limit=*) LIMIT="${arg#*=}" ;;
        --matchType=*) MATCH_TYPE="${arg#*=}" ;;
        --collapse=*) COLLAPSE="${arg#*=}" ;;
    esac
done

# Pastikan input pakai protokol
if [[ "$INPUT" =~ ^https?:// ]]; then
    FULL_URL="$INPUT"
else
    FULL_URL="https://$INPUT"
fi

# Encode untuk URL API
ENCODED_URL=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$FULL_URL'))")

# Ambil hanya domain tanpa skema untuk penamaan file
BARE_DOMAIN=$(echo "$INPUT" | sed -E 's~https?://~~' | sed 's~/.*~~')
OUTPUT_FILE="urls_${BARE_DOMAIN}.txt"

# Bangun URL API
URL="https://web.archive.org/web/timemap/json"
URL+="?url=$ENCODED_URL"
URL+="&matchType=$MATCH_TYPE"
URL+="&collapse=$COLLAPSE"
URL+="&output=json"
URL+="&limit=$LIMIT"

# Fetch dan simpan hasil
echo "[*] Querying: $URL"
curl -s "$URL" | jq -r '.[1:][] | .[2]' | sort -u > "$OUTPUT_FILE"

echo "[+] Saved to: $OUTPUT_FILE"
