#!/bin/bash

# Nama file yang berisi daftar URL
URL_FILE="urls.txt"
OUTPUT_FILE="hasil_check_urls.txt"

# Mengecek apakah file URL ada
if [ ! -f "$URL_FILE" ]; then
  echo "File $URL_FILE tidak ditemukan!" | tee "$OUTPUT_FILE"
  exit 1
fi

# Menampilkan header dan menyimpan ke file output
echo "Url;Protocol;http status;size;lines;location" | tee "$OUTPUT_FILE"

# Membaca file baris demi baris
while IFS= read -r url; do
  if [ -n "$url" ]; then
    # Menambahkan https:// jika belum ada di URL
    if [[ ! "$url" =~ ^https?:// ]]; then
      url="https://$url"
      protocol="https"
    else
      protocol="${url%%://*}"  # Menyimpan protokol (http atau https)
    fi

    # Fungsi untuk memeriksa URL dan menulis hasil ke output
    check_url() {
      local current_url=$1
      local current_protocol=$2

      # Mendapatkan status HTTP, ukuran konten, Location header (jika ada), dan jumlah baris dengan satu permintaan curl
      response=$(curl -k --max-time 2 -s -w "%{http_code} %{size_download} %{redirect_url}\n" -o temp_content.txt "$current_url")

      # Ekstrak status HTTP, ukuran konten, dan redirect URL
      http_code=$(echo "$response" | awk '{print $1}')
      size=$(echo "$response" | awk '{print $2}')
      location=$(echo "$response" | awk '{print $3}')

      # Menghitung jumlah baris jika file sementara ada
      if [ -f temp_content.txt ]; then
        lines=$(wc -l < temp_content.txt)
        # Menghapus file sementara setelah digunakan
        rm -f temp_content.txt
      else
        lines=0
      fi

      # Jika status bukan 000, tampilkan informasi dalam format yang diharapkan
      if [[ "$http_code" != "000" ]]; then
        # Jika ada redirect (3xx) dan Location tidak kosong, masukkan lokasi redirect
        if [[ "$http_code" =~ ^3 ]]; then
          location_info="$location"
        else
          location_info=""
        fi

        # Menampilkan hasil dan menyimpan ke file output
        echo "$current_url;$current_protocol;$http_code;$size;$lines;$location_info" | tee -a "$OUTPUT_FILE"
      fi
    }

    # Cek URL pertama dengan https
    check_url "$url" "$protocol"

    # Jika status 000 atau tidak ada respons, coba menggunakan http
    if [[ "$http_code" == "000" || -z "$http_code" ]]; then
      # Mengubah https menjadi http
      url_http="${url/https/http}"
      protocol_http="http"

      # Cek ulang menggunakan http
      check_url "$url_http" "$protocol_http"
    fi

    # Jika kedua percobaan (http dan https) gagal, catat bahwa URL gagal diakses
    if [[ "$http_code" == "000" || -z "$http_code" ]]; then
      echo "$url;Gagal diakses" | tee -a "$OUTPUT_FILE"
    fi

    # Memberikan jeda 1 detik sebelum memeriksa URL berikutnya
    sleep 1
  fi
done < "$URL_FILE"
