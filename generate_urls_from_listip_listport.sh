#!/bin/bash


# Kombinasi IP dan port otomatis
# File input
raw_ip_file="ip.txt"
port_file="port.txt"
output_file="urls.txt"
valid_ip_file="valid_ips.txt"

# Ekstrak IP walaupun nempel
tr -c '0-9.' '\n' < "$raw_ip_file" | \
grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | \
awk -F. '{
  for(i=1;i<=4;i++) if($i > 255) next;
  print $0
}' | sort -u > "$valid_ip_file"

# Kosongkan file output jika sudah ada
> "$output_file"

# Loop kombinasi IP dan Port
while IFS= read -r ip; do
  while IFS= read -r port; do
    echo "${ip}:${port}" >> "$output_file"
  done < "$port_file"
done < "$valid_ip_file"

echo "File $output_file berhasil dibuat."
