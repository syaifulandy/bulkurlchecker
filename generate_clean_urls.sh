#!/bin/bash

# Cek apakah user memasukkan argumen file
if [ -z "$1" ]; then
    echo "[ERROR] Penggunaan: $0 <nama_file_input>"
    echo "Contoh: ./bersihin.sh raw_urls.txt"
    exit 1
fi

input="$1"

# Cek apakah file inputnya beneran ada
if [ ! -f "$input" ]; then
    echo "[ERROR] File '$input' tidak ditemukan!"
    exit 1
fi

# Buat nama output dinamis: contoh_file.txt -> clean_contoh_file.txt
filename=$(basename "$input")
output="clean_$filename"

# Proses Ekstraksi (Logic yang sudah oke tadi)
cat "$input" | \
    tr ',' '\n' | \
    grep -oE '(https?://|www\.)[a-zA-Z0-9./?=&\-_%#+:]+|[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}[a-zA-Z0-9./?=&\-_%#+:]*' | \
    sed 's/[")>]*$//' | \
    sort -u > "$output"

echo "[+] Selesai! Input: $input"
echo "[+] Hasil bersih tersimpan di: $output"
