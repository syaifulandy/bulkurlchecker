#!/bin/bash

input="urldirlisting.txt"
output="outputalllinkurldirlisting.txt"

# === CHECK FILE INPUT ===
if [ ! -f "$input" ]; then
    echo "[ERROR] File '$input' tidak ditemukan!"
    echo "Buat file $input berisi URL directory listing per baris."
    exit 1
fi

# Bersihkan output
> "$output"

echo "[+] Memulai ekstraksi dari $input"
echo "[+] Dedup baris sebelum diproses"
echo

declare -A uniq_url

# === LOAD & DEDUP BARIS ===
while IFS= read -r raw; do
    # trim
    url="$(echo "$raw" | xargs)"

    # skip kosong
    [[ -z "$url" ]] && continue

    # skip komentar
    [[ "$url" =~ ^# ]] && continue

    uniq_url["$url"]=1
done < "$input"

echo "[+] Total unik URL yang akan diproses: ${#uniq_url[@]}"
echo

# === PROCESS PER URL UNIK ===
for url in "${!uniq_url[@]}"; do

    # basic validation
    if ! [[ "$url" =~ ^https?:// ]]; then
        echo "[ERROR] Format URL tidak valid, skip: $url" >&2
        continue
    fi

    # pastikan ada trailing slash
    base="${url%/}/"

    echo "[+] Processing: $base"

    # fetch halaman
    html=$(curl -s --max-time 10 "$base")
    if [ $? -ne 0 ] || [ -z "$html" ]; then
        echo "[ERROR] Gagal fetch $base (timeout atau unreachable)" >&2
        continue
    fi

    # extract link
    extracted=$(echo "$html" \
        | grep -oP '(?<=href=")[^"]+' \
        | grep -vE '^/|^\.\.' \
        || true)

    # jika tidak ada link
    if [[ -z "$extracted" ]]; then
        echo "[WARN] Tidak ditemukan link di halaman: $base" >&2
        continue
    fi

    # write ke output
    while read -r link; do
        echo "${base}${link}" >> "$output"
    done <<< "$extracted"

done

echo
echo "[+] DONE. Semua hasil tersimpan ke: $output"
