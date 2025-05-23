#!/bin/bash

URL_FILE="urls.txt"
OUTPUT_FILE="hasil_check_urls.txt"
TMP_SUCCESS=$(mktemp)
TMP_FAIL=$(mktemp)
TMP_RETRY=$(mktemp)

if [ ! -f "$URL_FILE" ]; then
  echo "File $URL_FILE tidak ditemukan!"
  exit 1
fi

echo "Url;Protocol;HTTP Status;Size;Lines;Location;Title" > "$OUTPUT_FILE"

check_url() {
  local raw_url="$1"
  local output_ok="$2"
  local output_fail="$3"

  if [[ ! "$raw_url" =~ ^https?:// ]]; then
    url_https="https://$raw_url"
  else
    url_https="$raw_url"
  fi

do_check() {
  local url="$1"
  local protocol="$2"
  local tmpfile
  tmpfile=$(mktemp)

  read -r http_code size_download redirect_url <<< $(curl -k --max-time 1 -s -L -w "%{http_code} %{size_download} %{redirect_url}" -o "$tmpfile" "$url")

  if [[ "$http_code" != "000" ]]; then
    lines=$(wc -l < "$tmpfile")
    title=$(grep -i -o '<title[^>]*>.*</title>' "$tmpfile" | head -n1 | sed -e 's/<title[^>]*>//I' -e 's#</title>##I' | tr -d '\n' | sed 's/;/,/g')
    [[ -z "$title" ]] && title="-"
    location=""
    [[ "$http_code" =~ ^3 ]] && location="$redirect_url"

    echo "$url;$protocol;$http_code;$size_download;$lines;$location;$title" | tee -a "$output_ok" >&2
    rm -f "$tmpfile"
    return 0
  fi

  rm -f "$tmpfile"
  return 1
}

  if do_check "$url_https" "https"; then return; fi
  url_http="${url_https/https:/http:}"
  if do_check "$url_http" "http"; then return; fi

  echo "$raw_url" >> "$output_fail"
}

export -f check_url

echo "▶️ Scan pertama dimulai..."
grep -v '^\s*$' "$URL_FILE" | xargs -P 40 -I{} bash -c 'check_url "$@"' _ {} "$TMP_SUCCESS" "$TMP_FAIL"

echo "🔁 Scan ulang untuk URL yang gagal..."
grep -v '^\s*$' "$TMP_FAIL" | xargs -P 30 -I{} bash -c 'check_url "$@"' _ {} "$TMP_SUCCESS" "$TMP_RETRY"

# Hapus duplikat
sort -u "$TMP_SUCCESS" >> "$OUTPUT_FILE"

# Tambahkan URL gagal setelah retry
if [ -s "$TMP_RETRY" ]; then
  echo "" >> "$OUTPUT_FILE"
  echo "# URL yang tetap gagal setelah retry:" >> "$OUTPUT_FILE"
  while read -r line; do
    echo "$line;Gagal diakses;;;;;" >> "$OUTPUT_FILE"
  done < "$TMP_RETRY"
fi

rm -f "$TMP_SUCCESS" "$TMP_FAIL" "$TMP_RETRY"

echo "✅ Selesai. Hasil disimpan di $OUTPUT_FILE"
