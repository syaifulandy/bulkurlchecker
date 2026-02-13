#!/bin/bash

URL_FILE="urls.txt"
OUTPUT_FILE="hasil_check_urls.txt"

TMP_SUCCESS=$(mktemp)
TMP_FAIL=$(mktemp)
TMP_RETRY=$(mktemp)
TMP_NEWTARGET=$(mktemp)

RETRY_MODE=false
INTERNET_MODE=false

# =========================
# CLEAN OUTPUT (FOR CSV)
# =========================
clean_field() {
  echo "$1" | tr -d '\r\n' | sed 's/;/,/g' | xargs
}

# =========================
# ARGUMENT PARSER
# =========================
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -r|--retry)
      RETRY_MODE=true
      ;;
    -i|--internet)
      INTERNET_MODE=true
      ;;
    *)
      echo "❌ Opsi tidak dikenal: $1"
      echo "Gunakan: $0 [--retry] [--internet]"
      exit 1
      ;;
  esac
  shift
done

if [ ! -f "$URL_FILE" ]; then
  echo "❌ File $URL_FILE tidak ditemukan!"
  exit 1
fi

# =========================
# HEADER OUTPUT
# =========================
echo "Url;Protocol;HTTP;Size;Lines;Redirect;Title;ServerInfo;IP;SSL_Expire;SSL_Status;Days_Left;SubjectCN;IssuerCN;TLS_Version;Cipher" \
  > "$OUTPUT_FILE"

# =========================
# INTERNET DNS RESOLVER
# =========================
resolve_internet_ip() {
  local host="$1"

  ip=$(dig +short @8.8.8.8 "$host" \
    | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | head -n1)

  echo "$ip"
}

# =========================
# PORTABLE DATE → EPOCH
# =========================
to_epoch() {
  local datestr="$1"

  datestr=$(echo "$datestr" \
    | sed 's/ GMT//' \
    | sed 's/^[A-Za-z]*,//' \
    | xargs)

  # Linux
  if date -d "$datestr" +%s >/dev/null 2>&1; then
    date -d "$datestr" +%s
    return
  fi

  # macOS
  date -jf "%b %d %T %Y" "$datestr" "+%s" 2>/dev/null
}

# =========================
# MAIN CHECK FUNCTION
# =========================
check_url() {

  local raw_url="$1"
  local output_ok="$2"
  local output_fail="$3"
  local output_new="$4"

  do_check() {

    local url="$1"
    local protocol="$2"

    local tmpfile=$(mktemp)
    local tmpheader=$(mktemp)
    local tmplog=$(mktemp)

    url=$(echo "$url" | tr -d '\r' | xargs)
    host=$(echo "$url" | sed -E 's#https?://##' | cut -d/ -f1)

    curl_extra=""

    # =========================
    # INTERNET MODE ENABLED
    # =========================
    if $INTERNET_MODE && [[ "$protocol" == "https" ]]; then
      resolved_ip=$(resolve_internet_ip "$host")
      if [[ -n "$resolved_ip" ]]; then
        curl_extra="--resolve $host:443:$resolved_ip"
      fi
    fi

    # =========================
    # SINGLE CURL HIT
    # =========================
    curl_out=$(curl -4 -k --max-time 20 -s \
      $curl_extra \
      -D "$tmpheader" \
      -o "$tmpfile" \
      -w "%{http_code}|%{size_download}|%{redirect_url}|%{remote_ip}" \
      -v "$url" 2> "$tmplog")

    IFS="|" read -r http_code size_download redirect_url remote_ip <<< "$curl_out"

    if [[ "$http_code" == "000" ]]; then
      rm -f "$tmpfile" "$tmpheader" "$tmplog"
      return 1
    fi

    lines=$(wc -l < "$tmpfile")

    # =========================
    # TITLE EXTRACT
    # =========================
    title=$(grep -i -o '<title[^>]*>.*</title>' "$tmpfile" \
      | head -n1 \
      | sed -e 's/<title[^>]*>//I' -e 's#</title>##I')

    [[ -z "$title" ]] && title="-"

    # Redirect
    location=""
    [[ "$http_code" =~ ^3 ]] && location="$redirect_url"

    # Server info
    server_info=$(grep -Ei '^(server|x-powered-by|via|x-runtime):' "$tmpheader" \
      | paste -sd ' | ' -)

    [[ -z "$server_info" ]] && server_info="-"

    # =========================
    # SSL + CERT DETAILS
    # =========================
    ssl_expire="-"
    ssl_status="-"
    days_left="-"

    subject_cn="-"
    issuer_cn="-"
    tls_version="-"
    cipher="-"

    if [[ "$protocol" == "http" ]]; then
      ssl_status="NO_TLS"

    else
      ssl_expire=$(grep -i "expire date:" "$tmplog" \
        | head -n1 | cut -d: -f2-)

      subject_cn=$(grep -i "subject:" "$tmplog" \
        | head -n1 \
        | sed -E 's/.*CN=([^;]+).*/\1/')

      issuer_cn=$(grep -i "issuer:" "$tmplog" \
        | head -n1 \
        | sed -E 's/.*CN=([^;]+).*/\1/')

      tls_line=$(grep -i "SSL connection using" "$tmplog" | head -n1)

      if [[ -n "$tls_line" ]]; then
        tls_version=$(echo "$tls_line" | awk '{print $5}')
        cipher=$(echo "$tls_line" | awk '{print $7}')
      fi

      # Status Logic
      if [[ -z "$ssl_expire" ]]; then
        ssl_status="NO_CERT"
        ssl_expire="-"
      else
        expire_epoch=$(to_epoch "$ssl_expire")
        now_epoch=$(date +%s)

        if [[ -z "$expire_epoch" ]]; then
          ssl_status="UNKNOWN_DATE"
        elif (( expire_epoch < now_epoch )); then
          ssl_status="EXPIRED"
          days_left=0
        else
          ssl_status="VALID"
          days_left=$(( (expire_epoch - now_epoch) / 86400 ))
        fi
      fi

      if grep -qi "self signed certificate" "$tmplog"; then
        ssl_status="SELF_SIGNED"
      fi
    fi

    [[ -z "$remote_ip" ]] && remote_ip="-"

    # =========================
    # CLEAN ALL FIELDS
    # =========================
    title=$(clean_field "$title")
    server_info=$(clean_field "$server_info")
    subject_cn=$(clean_field "$subject_cn")
    issuer_cn=$(clean_field "$issuer_cn")
    tls_version=$(clean_field "$tls_version")
    cipher=$(clean_field "$cipher")
    ssl_expire=$(clean_field "$ssl_expire")
    location=$(clean_field "$location")

    # =========================
    # OUTPUT (ALWAYS 1 LINE)
    # =========================
    echo "$url;$protocol;$http_code;$size_download;$lines;$location;$title;$server_info;$remote_ip;$ssl_expire;$ssl_status;$days_left;$subject_cn;$issuer_cn;$tls_version;$cipher" \
      | tee -a "$output_ok" >&2

    # Add redirect target
    if [[ "$http_code" =~ ^3 ]] && [[ -n "$redirect_url" ]]; then
      echo "$redirect_url" >> "$output_new"
    fi

    rm -f "$tmpfile" "$tmpheader" "$tmplog"
    return 0
  }

  # =========================
  # PROTOCOL TRY
  # =========================
  if [[ "$raw_url" =~ ^https?:// ]]; then
    proto=$(echo "$raw_url" | cut -d':' -f1)
    if do_check "$raw_url" "$proto"; then return; fi
  else
    if do_check "https://$raw_url" "https"; then return; fi
    if do_check "http://$raw_url" "http"; then return; fi
  fi

  echo "$raw_url" >> "$output_fail"
}

export -f check_url
export -f resolve_internet_ip
export -f to_epoch
export -f clean_field
export INTERNET_MODE

# =========================
# FIRST SCAN
# =========================
echo "▶️ Scan pertama dimulai..."
grep -v '^\s*$' "$URL_FILE" | sort -u \
  | xargs -P 40 -I{} bash -c 'check_url "$@"' _ {} "$TMP_SUCCESS" "$TMP_FAIL" "$TMP_NEWTARGET"

# =========================
# RETRY MODE
# =========================
if $RETRY_MODE; then
  echo "🔁 Retry URL gagal..."
  grep -v '^\s*$' "$TMP_FAIL" | sort -u \
    | xargs -P 20 -I{} bash -c 'check_url "$@"' _ {} "$TMP_SUCCESS" "$TMP_RETRY" "$TMP_NEWTARGET"
else
  cp "$TMP_FAIL" "$TMP_RETRY"
fi

# =========================
# REDIRECT SCAN
# =========================
echo "➡️ Scan redirect target..."
if [ -s "$TMP_NEWTARGET" ]; then
  sort -u "$TMP_NEWTARGET" \
    | xargs -P 30 -I{} bash -c 'check_url "$@"' _ {} "$TMP_SUCCESS" /dev/null /dev/null
fi

# =========================
# FINAL OUTPUT
# =========================
sort -u "$TMP_SUCCESS" >> "$OUTPUT_FILE"

if [ -s "$TMP_RETRY" ]; then
  echo "" >> "$OUTPUT_FILE"
  echo "# URL gagal setelah retry:" >> "$OUTPUT_FILE"
  while read -r line; do
    echo "$line;Gagal;;;;;;;-" >> "$OUTPUT_FILE"
  done < "$TMP_RETRY"
fi

rm -f "$TMP_SUCCESS" "$TMP_FAIL" "$TMP_RETRY" "$TMP_NEWTARGET"

echo "✅ Done. Output: $OUTPUT_FILE"
