#!/bin/bash

############################################
# CONFIG
############################################

INPUT="target.txt"
OUTPUT="php_version.csv"
PARALLEL=30
RETRY=1

############################################
# HELP
############################################

show_help() {
cat << EOF

Usage:
  $0 [options]

Options:
  -i FILE   Input file (default: target.txt)
  -o FILE   Output file (default: php_version.csv)
  -p NUM    Parallel workers (default: 30)
  -r NUM    Retry count (default: 1)
  -h        Show help

Examples:
  $0
  $0 -i domains.txt
  $0 -o result.csv
  $0 -p 50 -r 2
  $0 -i domains.txt -o result.csv -p 100 -r 3

EOF
exit 0
}

while getopts "i:o:p:r:h" opt; do
    case $opt in
        i) INPUT="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        p) PARALLEL="$OPTARG" ;;
        r) RETRY="$OPTARG" ;;
        h) show_help ;;
    esac
done

############################################
# CHECK INPUT
############################################

if [[ ! -f "$INPUT" ]]; then
    echo "[ERROR] Input file not found: $INPUT"
    exit 1
fi

############################################
# TMP
############################################

WORKDIR=$(mktemp -d)

CSV_DIR="$WORKDIR/csv"
FAILED_DIR="$WORKDIR/failed"

mkdir -p "$CSV_DIR"
mkdir -p "$FAILED_DIR"

export CSV_DIR
export FAILED_DIR

############################################
# DNS RESOLVE
############################################

resolve_ip() {

    local host="$1"
    local ip=""

    ip=$(curl -s \
        --connect-timeout 3 \
        --max-time 5 \
        "https://cloudflare-dns.com/dns-query?name=${host}&type=A" \
        -H "accept: application/dns-json" \
        2>/dev/null \
        | jq -r '.Answer[]?.data' 2>/dev/null \
        | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
        | head -n1)

    if [[ -z "$ip" ]]; then
        ip=$(dig +short "$host" A 2>/dev/null \
            | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
            | head -n1)
    fi

    echo "$ip"
}

############################################
# CLEAN CSV FIELD
############################################

clean_field() {

    echo "$1" \
        | tr '\r\n' ' ' \
        | sed 's/[[:space:]]\+/ /g' \
        | sed 's/^ *//;s/ *$//'
}

############################################
# URL NORMALIZATION
############################################

normalize_url() {

    local target="$1"

    if [[ "$target" =~ ^https?:// ]]; then
        echo "$target"
        return
    fi

    if curl -ksI \
        --connect-timeout 3 \
        --max-time 5 \
        "https://$target" >/dev/null 2>&1; then

        echo "https://$target"
        return
    fi

    if curl -sI \
        --connect-timeout 3 \
        --max-time 5 \
        "http://$target" >/dev/null 2>&1; then

        echo "http://$target"
        return
    fi

    echo "https://$target"
}

############################################
# PROCESS URL
############################################

process_url() {

    local raw_url="$1"

    [[ -z "$raw_url" ]] && return

    raw_url=$(echo "$raw_url" | xargs)

    [[ -z "$raw_url" ]] && return
    [[ "$raw_url" =~ ^# ]] && return

    url=$(normalize_url "$raw_url")

    host=$(echo "$url" \
        | sed -E 's#https?://##' \
        | cut -d/ -f1 \
        | cut -d: -f1)

    hash=$(echo -n "$url" | shasum | awk '{print $1}')

    ip=$(resolve_ip "$host")

    response=$(curl -ksI \
        --connect-timeout 5 \
        --max-time 15 \
        -w "\nHTTPSTATUS:%{http_code}" \
        "$url" 2>/dev/null)

    status_code=$(echo "$response" \
        | sed -n 's/^HTTPSTATUS://p')

    headers=$(echo "$response" \
        | sed '/^HTTPSTATUS:/d')

    server=$(echo "$headers" \
    | grep -im1 '^server:' \
    | sed 's/^[Ss]erver:[[:space:]]*//' \
    | tr -d '\r')

    x_powered_by=$(echo "$headers" \
    | grep -im1 '^x-powered-by:' \
    | sed 's/^[Xx]-[Pp]owered-[Bb]y:[[:space:]]*//' \
    | tr -d '\r')

    php_version=$(echo "$x_powered_by" \
    | grep -oE 'PHP/[0-9.]+' \
    | head -n1 \
    | cut -d/ -f2 \
    | tr -d '\r')


    server=$(clean_field "$server")
    x_powered_by=$(clean_field "$x_powered_by")
    php_version=$(clean_field "$php_version")

    server=${server//\"/\"\"}
    x_powered_by=${x_powered_by//\"/\"\"}
    php_version=${php_version//\"/\"\"}
    
    [[ -z "$status_code" ]] && status_code="000"
    [[ -z "$ip" ]] && ip="N/A"
    [[ -z "$server" ]] && server="N/A"
    [[ -z "$x_powered_by" ]] && x_powered_by="N/A"
    [[ -z "$php_version" ]] && php_version="N/A"

    echo "\"$url\",\"$ip\",\"$status_code\",\"$server\",\"$x_powered_by\",\"$php_version\"" \
        > "$CSV_DIR/${hash}.csv"

    if [[ "$status_code" == "000" ]]; then
        echo "$raw_url" > "$FAILED_DIR/${hash}.txt"
    fi

    printf "[%s] %s | %s\n" \
        "$status_code" \
        "$host" \
        "$php_version"
}

export -f resolve_ip
export -f clean_field
export -f normalize_url
export -f process_url

############################################
# PASS 1
############################################

echo "[*] Input    : $INPUT"
echo "[*] Output   : $OUTPUT"
echo "[*] Parallel : $PARALLEL"
echo "[*] Retry    : $RETRY"
echo

grep -v '^[[:space:]]*$' "$INPUT" \
| xargs -P "$PARALLEL" -I{} bash -c 'process_url "$1"' _ "{}"

############################################
# RETRY
############################################

for ((i=1;i<=RETRY;i++)); do

    FAILED_COUNT=$(find "$FAILED_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')

    [[ "$FAILED_COUNT" == "0" ]] && break

    echo
    echo "[*] Retry Pass $i ($FAILED_COUNT targets)"

    RETRY_FILE=$(mktemp)

    find "$FAILED_DIR" -type f -exec cat {} \; \
        | sort -u > "$RETRY_FILE"

    rm -f "$FAILED_DIR"/*.txt 2>/dev/null

    cat "$RETRY_FILE" \
    | xargs -P "$PARALLEL" -I{} bash -c 'process_url "$1"' _ "{}"

    rm -f "$RETRY_FILE"

done

############################################
# BUILD OUTPUT
############################################

echo "url,ip,status_code,server,x_powered_by,php_version" > "$OUTPUT"

find "$CSV_DIR" -name "*.csv" -type f \
| sort \
| while read f; do
    cat "$f"
done >> "$OUTPUT"

FINAL_FAILED=$(find "$FAILED_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')

echo
echo "========================================"
echo "Done"
echo "Output File : $OUTPUT"
echo "Failed      : $FINAL_FAILED"
echo "========================================"

rm -rf "$WORKDIR"
