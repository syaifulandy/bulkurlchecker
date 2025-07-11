#!/bin/bash

INPUT="dns.txt"
OUTPUT_OK="resolved_domains.txt"
OUTPUT_FAIL="unresolved_domains.txt"

# Cek apakah file input ada
if [ ! -f "$INPUT" ]; then
  echo "❌ File '$INPUT' tidak ditemukan. Pastikan file tersebut ada di direktori ini."
  exit 1
fi

# Kosongkan file output
> "$OUTPUT_OK"
> "$OUTPUT_FAIL"

echo "📄 Memulai pengecekan domain dari file: $INPUT"
echo "=============================================="

while IFS= read -r domain || [[ -n "$domain" ]]; do
  # Bersihkan spasi dan karakter tak terlihat
  domain=$(echo "$domain" | tr -d '\r' | xargs)

  if [ -z "$domain" ]; then
    continue
  fi

  # Cek A record
  IPs=$(dig +short "$domain" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
  if [ -n "$IPs" ]; then
    echo "$domain -> $IPs" >> "$OUTPUT_OK"
    echo "✅ $domain resolved to: $IPs"
    continue
  fi

  # Cek CNAME jika tidak ada A
  CNAME=$(dig +short "$domain" CNAME)
  if [ -n "$CNAME" ]; then
    echo "$domain -> CNAME: $CNAME" >> "$OUTPUT_OK"
    echo "✅ $domain has CNAME: $CNAME"
    continue
  fi

  # Tidak resolve
  echo "$domain" >> "$OUTPUT_FAIL"
  echo "❌ $domain NOT resolved"
done < "$INPUT"

echo "=============================================="
echo "✅ Selesai. Lihat hasil di '$OUTPUT_OK' dan '$OUTPUT_FAIL'."
