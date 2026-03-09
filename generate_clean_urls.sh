#!/bin/bash

input="raw_urls.txt"
output="clean_urls.txt"

if [ ! -f "$input" ]; then
    echo "[ERROR] File $input tidak ditemukan"
    exit 1
fi

> "$output"

while IFS= read -r line; do

    # hapus spasi depan belakang
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # hapus tanda kutip
    line=$(echo "$line" | tr -d '"')

    # skip kosong
    [[ -z "$line" ]] && continue

    # hapus teks dalam ()
    line=$(echo "$line" | sed 's/(.*)//')

    # ambil token pertama
    url=$(echo "$line" | awk '{print $1}')

    # tambah https jika belum ada
    if [[ ! "$url" =~ ^https?:// ]]; then
        url="https://$url"
    fi

    echo "$url"

done < "$input" | sort -u > "$output"

echo "[+] Clean URL tersimpan di $output"
