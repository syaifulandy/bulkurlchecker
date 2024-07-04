#!/bin/bash

# Nama file yang berisi daftar URL
URL_FILE="urls.txt"

# Mengecek apakah file URL ada
if [ ! -f "$URL_FILE" ]; then
  echo "File $URL_FILE tidak ditemukan!"
  exit 1
fi

# Menampilkan header
echo "Url;http status;size;lines"

# Membaca file baris demi baris
while IFS= read -r url; do
  if [ -n "$url" ]; then
    # Mendapatkan status HTTP dan ukuran konten dengan timeout 2 detik
    response=$(curl -s --max-time 2 -o /dev/null -w "%{http_code} %{size_download}" "$url")
    http_code=$(echo $response | awk '{print $1}')
    size=$(echo $response | awk '{print $2}')

    # Mendapatkan jumlah baris dengan timeout 2 detik
    content=$(curl -s --max-time 2 "$url")
    lines=$(echo "$content" | wc -l)

    # Menampilkan informasi dalam format yang diharapkan
    echo "$url;$http_code;$size;$lines"
  fi
done < "$URL_FILE"
