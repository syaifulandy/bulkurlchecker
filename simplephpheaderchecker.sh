#!/bin/bash

echo "url,server,versi_php" > php_version.csv

while read -r url; do
    [ -z "$url" ] && continue

    headers=$(curl -ksI --max-time 10 "$url")

    server=$(echo "$headers" | sed -nE '/^Server:/Ip' | head -1 | sed -E 's/^Server:[[:space:]]*//I' | tr -d '\r')

    php_version=$(echo "$headers" | sed -nE '/^X-Powered-By:/Ip' | grep -oiE 'PHP/[0-9.]+' | cut -d/ -f2)

    echo "\"$url\",\"${server:-N/A}\",\"${php_version:-N/A}\"" >> php_version.csv

done < target.txt
