#!/bin/bash

URL_FILE="urls.txt"
OUTPUT_FILE="hasil_check_urls.csv"

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
# DOMAIN EXTRACTOR
# =========================
get_domain() {
  # Menghapus protocol dan path/query untuk mendapatkan domain/host saja
  echo "$1" | sed -E 's#https?://##' | cut -d/ -f1 | sed 's/^www\.//'
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
# HEADER OUTPUT (TAMBAHAN KOLOM: External_Redirect)
# =========================
echo "Url;Protocol;HTTP;Size;Lines;Redirect;External_Redirect;Title;ServerInfo;IP;SSL_Expire;SSL_Status;Days_Left;SubjectCN;IssuerCN;TLS_Version;Cipher" \
  > "$OUTPUT_FILE"

# =========================
# INTERNET DNS RESOLVER
# =========================
resolve_internet_ip() {
  local host="$1"
  local ip=""

  [[ ! "$host" =~ ^[a-zA-Z0-9.-]+$ ]] && return 1

  # curl request ke DoH
  ip=$(curl -s \
    --max-time 5 \
    --connect-timeout 3 \
    --retry 2 \
    --retry-delay 1 \
    --fail \
    "https://cloudflare-dns.com/dns-query?name=${host}&type=A" \
    -H "accept: application/dns-json" \
    | jq -r '.Answer[].data' 2>/dev/null \
    | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | head -n1)

  # fallback ke DNS biasa
  if [ -z "$ip" ]; then
    ip=$(dig +short "$host" 2>/dev/null | head -n1)
  fi

  echo "$ip"
}

# =========================
# PORTABLE DATE → EPOCH
# =========================
to_epoch() {
  local datestr="$1"
  datestr=$(echo "$datestr" | sed 's/ GMT//' | sed 's/^[A-Za-z]*,//' | xargs)
  if date -d "$datestr" +%s >/dev/null 2>&1; then
    date -d "$datestr" +%s
    return
  fi
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
    if $INTERNET_MODE && [[ "$protocol" == "https" ]]; then
      resolved_ip=$(resolve_internet_ip "$host")
      [[ -n "$resolved_ip" ]] && curl_extra="--resolve $host:443:$resolved_ip"
    fi

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
    # REDIRECT LOGIC (NEW)
    # =========================
    location="-"
    is_external="No"
    
    if [[ "$http_code" =~ ^3 ]] && [[ -n "$redirect_url" ]]; then
      location="$redirect_url"
      
      orig_domain=$(get_domain "$url")
      dest_domain=$(get_domain "$redirect_url")
      
      if [[ "$orig_domain" != "$dest_domain" ]]; then
        is_external="Yes"
      fi
    fi

    # =========================
    # TITLE & SERVER INFO
    # =========================
    title=$(grep -i -o '<title[^>]*>.*</title>' "$tmpfile" | head -n1 | sed -e 's/<title[^>]*>//I' -e 's#</title>##I')
    [[ -z "$title" ]] && title="-"
    server_info=$(grep -Ei '^(server|x-powered-by|via|x-runtime):' "$tmpheader" | paste -sd ' | ' -)
    [[ -z "$server_info" ]] && server_info="-"

    # =========================
    # SSL + CERT DETAILS
    # =========================
    ssl_expire="-"; ssl_status="-"; days_left="-"; subject_cn="-"; issuer_cn="-"; tls_version="-"; cipher="-"

    if [[ "$protocol" == "http" ]]; then
      ssl_status="NO_TLS"
    else
      ssl_expire=$(grep -i "expire date:" "$tmplog" | head -n1 | cut -d: -f2-)
      subject_cn=$(grep -i "subject:" "$tmplog" | head -n1 | sed -E 's/.*CN=([^;]+).*/\1/')
      issuer_cn=$(grep -i "issuer:" "$tmplog" | head -n1 | sed -E 's/.*CN=([^;]+).*/\1/')
      tls_line=$(grep -i "SSL connection using" "$tmplog" | head -n1)
      if [[ -n "$tls_line" ]]; then
        tls_version=$(echo "$tls_line" | awk '{print $5}')
        cipher=$(echo "$tls_line" | awk '{print $7}')
      fi

      if [[ -z "$ssl_expire" ]]; then
        ssl_status="NO_CERT"
      else
        expire_epoch=$(to_epoch "$ssl_expire")
        now_epoch=$(date +%s)
        if [[ -z "$expire_epoch" ]]; then
          ssl_status="UNKNOWN_DATE"
        elif (( expire_epoch < now_epoch )); then
          ssl_status="EXPIRED"; days_left=0
        else
          ssl_status="VALID"; days_left=$(( (expire_epoch - now_epoch) / 86400 ))
        fi
      fi
      grep -qi "self signed certificate" "$tmplog" && ssl_status="SELF_SIGNED"
    fi

    [[ -z "$remote_ip" ]] && remote_ip="-"

    # Clean fields
    title=$(clean_field "$title")
    server_info=$(clean_field "$server_info")
    subject_cn=$(clean_field "$subject_cn")
    issuer_cn=$(clean_field "$issuer_cn")
    tls_version=$(clean_field "$tls_version")
    cipher=$(clean_field "$cipher")
    ssl_expire=$(clean_field "$ssl_expire")
    location=$(clean_field "$location")

    # =========================
    # OUTPUT (WITH External_Redirect)
    # =========================
    echo "$url;$protocol;$http_code;$size_download;$lines;$location;$is_external;$title;$server_info;$remote_ip;$ssl_expire;$ssl_status;$days_left;$subject_cn;$issuer_cn;$tls_version;$cipher" \
      | tee -a "$output_ok" >&2

    if [[ "$http_code" =~ ^3 ]] && [[ -n "$redirect_url" ]]; then
      echo "$redirect_url" >> "$output_new"
    fi

    rm -f "$tmpfile" "$tmpheader" "$tmplog"
    return 0
  }

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
export -f get_domain
export INTERNET_MODE

# Execution Logic (First Scan, Retry, Redirect Scan) tetap sama...
echo "▶️ Scan pertama dimulai..."
grep -v '^\s*$' "$URL_FILE" | sort -u | xargs -P 40 -I{} bash -c 'check_url "$@"' _ {} "$TMP_SUCCESS" "$TMP_FAIL" "$TMP_NEWTARGET"

if $RETRY_MODE; then
  echo "🔁 Retry URL gagal..."
  grep -v '^\s*$' "$TMP_FAIL" | sort -u | xargs -P 20 -I{} bash -c 'check_url "$@"' _ {} "$TMP_SUCCESS" "$TMP_RETRY" "$TMP_NEWTARGET"
else
  cp "$TMP_FAIL" "$TMP_RETRY"
fi

echo "➡️ Scan redirect target..."
if [ -s "$TMP_NEWTARGET" ]; then
  sort -u "$TMP_NEWTARGET" | xargs -P 30 -I{} bash -c 'check_url "$@"' _ {} "$TMP_SUCCESS" /dev/null /dev/null
fi

sort -u "$TMP_SUCCESS" >> "$OUTPUT_FILE"

if [ -s "$TMP_RETRY" ]; then
  echo "" >> "$OUTPUT_FILE"
  echo "# URL gagal setelah retry:" >> "$OUTPUT_FILE"
  while read -r line; do
    echo "$line;Gagal;;;;;;;;-" >> "$OUTPUT_FILE"
  done < "$TMP_RETRY"
fi

rm -f "$TMP_SUCCESS" "$TMP_FAIL" "$TMP_RETRY" "$TMP_NEWTARGET"
echo "✅ Done. Output: $OUTPUT_FILE"
