#!/bin/bash

URL_FILE="urls.txt"
OUTPUT_FILE="hasil_check_urls.txt"
TMP_OUTPUT=$(mktemp)

# Mengecek apakah file URL ada
if [ ! -f "$URL_FILE" ]; then
  echo "File $URL_FILE tidak ditemukan!" | tee "$OUTPUT_FILE"
  exit 1
fi

# Header output
echo "Url;Protocol;HTTP Status;Size;Lines;Location" > "$OUTPUT_FILE"

# Fungsi cek URL
check_url() {
  local raw_url="$1"
  local output_file="$2"

  # Tambahkan protokol jika tidak ada
  if [[ ! "$raw_url" =~ ^https?:// ]]; then
    url_https="https://$raw_url"
  else
    url_https="$raw_url"
  fi

  do_check() {
    local url="$1"
    local protocol="$2"

    # Ambil header info tanpa output konten ke terminal
    response=$(curl -k --max-time 1 -s -w "%{http_code} %{size_download} %{redirect_url}" -o /dev/null "$url")
    http_code=$(echo "$response" | awk '{print $1}')
    size=$(echo "$response" | awk '{print $2}')
    location=$(echo "$response" | cut -d' ' -f3-)

    # Hitung jumlah baris isi konten
    lines=$(curl -k --max-time 1 -s "$url" | wc -l)

    if [[ "$http_code" != "000" ]]; then
      if [[ "$http_code" =~ ^3 ]]; then
        location_info="$location"
      else
        location_info=""
      fi
      echo "$url;$protocol;$http_code;$size;$lines;$location_info" | tee -a "$output_file"
      return 0
    fi
    return 1
  }

  # Coba dengan HTTPS dulu
  if do_check "$url_https" "https"; then
    return
  fi

  # Jika gagal, coba dengan HTTP
  url_http="${url_https/https:/http:}"
  if do_check "$url_http" "http"; then
    return
  fi

  # Gagal dua-duanya
  echo "$raw_url;Gagal diakses" | tee -a "$output_file"
}

# Ekspor fungsi agar bisa digunakan di subprocess
export -f check_url

# Jalankan secara paralel (10 proses) menggunakan xargs
grep -v '^\s*$' "$URL_FILE" | xargs -P 10 -I{} bash -c 'check_url "$@"' _ {} "$TMP_OUTPUT"

# Gabungkan hasil sesuai urutan dan simpan
sort -t ';' -k1,1 "$TMP_OUTPUT" >> "$OUTPUT_FILE"
rm -f "$TMP_OUTPUT"

echo "✅ Selesai. Hasil disimpan di $OUTPUT_FILE"
