#!/bin/bash

URL_FILE="urls.txt"
OUTPUT_FILE="hasil_check_urls.txt"
TMP_SUCCESS=$(mktemp)
TMP_FAIL=$(mktemp)
TMP_RETRY=$(mktemp)
TMP_NEWTARGET=$(mktemp)  # Untuk menyimpan URL hasil redirect

RETRY_MODE=false

# Cek argumen
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -r|--retry)
      RETRY_MODE=true
      ;;
    *)
      echo "❌ Opsi tidak dikenal: $1"
      echo "Gunakan: $0 [--retry]"
      exit 1
      ;;
  esac
  shift
done

if [ ! -f "$URL_FILE" ]; then
  echo "File $URL_FILE tidak ditemukan!"
  exit 1
fi

# Header output
echo "Url;Protocol;HTTP Status;Size;Lines;Location;Title;ServerInfo" > "$OUTPUT_FILE"

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

    # Ambil header + body
    read -r http_code size_download redirect_url <<< "$(curl -k --max-time 5 -s -D "$tmpheader" -w "%{http_code} %{size_download} %{redirect_url}" -o "$tmpfile" "$url")"

    if [[ "$http_code" != "000" ]]; then
      lines=$(wc -l < "$tmpfile")

      title=$(grep -i -o '<title[^>]*>.*</title>' "$tmpfile" | head -n1 | sed -e 's/<title[^>]*>//I' -e 's#</title>##I' | tr -d '\n' | sed 's/;/,/g')
      [[ -z "$title" ]] && title="-"

      location=""
      [[ "$http_code" =~ ^3 ]] && location="$redirect_url"

      # Ambil info header server-related
      server_info=$(grep -Ei '^(server|x-powered-by|via|x-aspnet-version|x-backend-server|x-runtime):' "$tmpheader" | tr -d '\r' | paste -sd ' | ' -)
      [[ -z "$server_info" ]] && server_info="-"

      echo "$url;$protocol;$http_code;$size_download;$lines;$location;$title;$server_info" | tee -a "$output_ok" >&2	      

      # Tambah URL redirect ke antrian baru
      if [[ "$http_code" =~ ^3 ]] && [[ -n "$redirect_url" ]]; then
        echo "$redirect_url" >> "$output_new"
      fi

      rm -f "$tmpfile" "$tmpheader"
      return 0
    fi

    rm -f "$tmpfile" "$tmpheader"
    return 1
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

echo "▶️ Scan pertama dimulai..."
grep -v '^\s*$' "$URL_FILE" | sort -u | xargs -P 40 -I{} bash -c 'check_url "$@"' _ {} "$TMP_SUCCESS" "$TMP_FAIL" "$TMP_NEWTARGET"

if $RETRY_MODE; then
  echo "🔁 Scan ulang untuk URL yang gagal..."
  grep -v '^\s*$' "$TMP_FAIL" | sort -u | xargs -P 30 -I{} bash -c 'check_url "$@"' _ {} "$TMP_SUCCESS" "$TMP_RETRY" "$TMP_NEWTARGET"
else
  cp "$TMP_FAIL" "$TMP_RETRY"  # agar tetap tercatat yang gagal
  echo "⚠️  Retry dinonaktifkan. Lewati scan ulang URL gagal."
fi

echo "➡️ Scan URL hasil redirect..."
if [ -s "$TMP_NEWTARGET" ]; then
  sort -u "$TMP_NEWTARGET" | xargs -P 30 -I{} bash -c 'check_url "$@"' _ {} "$TMP_SUCCESS" /dev/null /dev/null
fi

# Gabungkan hasil sukses (unik)
sort -u "$TMP_SUCCESS" >> "$OUTPUT_FILE"

# Tambahkan URL gagal setelah retry
if [ -s "$TMP_RETRY" ]; then
  echo "" >> "$OUTPUT_FILE"
  echo "# URL yang tetap gagal setelah retry:" >> "$OUTPUT_FILE"
  while read -r line; do
    echo "$line;Gagal diakses;;;;;;" >> "$OUTPUT_FILE"
  done < "$TMP_RETRY"
fi

# Cleanup
rm -f "$TMP_SUCCESS" "$TMP_FAIL" "$TMP_RETRY" "$TMP_NEWTARGET"

echo "✅ Selesai. Hasil disimpan di $OUTPUT_FILE"
