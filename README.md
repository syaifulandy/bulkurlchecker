**Cara Penggunaan:**
1. Buat file teks bernama urls.txt dan isikan dengan URL yang ingin diperiksa, satu URL per baris, misalnya:
    https://tes.com
    https://tes1.com
3. Berikan izin eksekusi pada skrip dengan perintah: chmod +x check_urls.sh.
4. Jalankan skrip dengan perintah: ./check_urls.sh.
5. Skrip ini akan menampilkan output yang diharapkan dengan format:
    Url;http status;size;lines
    https://tes.com;200;4700;100
    https://tes1.com;302;1000;200
