#!/usr/bin/env python3
"""PHP fingerprinting berbasis bukti, untuk aset yang diizinkan saja.
Python >= 3.10. Dependensi: requests; playwright opsional.
"""
import argparse
import asyncio
import csv
import ipaddress
import json
import re
from collections import defaultdict
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit, urlunsplit

import requests

MAX_BODY = 1024 * 1024
UA = "Authorized-PHP-Fingerprint/3.0"

# Pola spesifik; kata umum seperti csrf-token, XSRF-TOKEN, /build/assets/
# dan status HTTP tidak dipakai sebagai bukti framework.
RULES = {
    "WordPress": [r"/(?:wp-content|wp-includes)/"],
    "Drupal": [r"data-drupal-selector\s*=", r"drupal-settings-json"],
    "Joomla": [r"Joomla\.getOptions\s*\(", r"/media/system/js/core(?:\.min)?\.js"],
    "Laravel Livewire": [r"\bwire:(?:id|snapshot)\s*=", r"/livewire/livewire(?:\.min)?\.js"],
    "Symfony": [r"Symfony\\Component\\", r"/_wdt/[a-z0-9]+"],
    "Yii": [r"/assets/[^\s\"']+/yii(?:\.min)?\.js"],
    "Magento": [r"text/x-magento-init", r"Magento_Ui/"],
    "PrestaShop": [r"\bprestashop\s*=\s*\{"],
    "OpenCart": [r"index\.php\?route=common/home"],
    "Moodle": [r"\bM\.cfg\s*=\s*\{"],
    "MediaWiki": [r"\bmw\.config\.set\s*\("],
    "CakePHP": [r"Cake\\(?:Controller|Http|Core)\\"],
    "Laminas": [r"Laminas\\(?:Mvc|Http|View)\\"],
    "Zend Framework": [r"Zend\\(?:Mvc|Http|View)\\"],
    "ThinkPHP": [r"ThinkPHP\s+V?\d+\.\d+"],
    "OctoberCMS": [r"/modules/system/assets/js/framework(?:\.combined)?\.js"],
}
GENERATORS = {
    "WordPress": "WordPress", "Drupal": "Drupal", "Joomla": "Joomla",
    "PrestaShop": "PrestaShop", "MediaWiki": "MediaWiki", "Moodle": "Moodle",
    "TYPO3": "TYPO3", "Grav": "Grav", "MODX": "MODX",
    "Concrete CMS": "concrete(?:5| cms)", "Contao": "Contao",
}
COOKIE_RULES = {
    "laravel_session": ("Laravel", 80),
    "ci_session": ("CodeIgniter", 65),
    "cakephp": ("CakePHP", 70),
    "moodlesession": ("Moodle", 80),
}


def normalize(value):
    value = value.strip()
    if not value or value.startswith("#"):
        return None
    # IPv6 polos perlu tanda kurung sebelum dijadikan URL.
    try:
        ip = ipaddress.ip_address(value)
        value = f"[{ip}]" if ip.version == 6 else str(ip)
    except ValueError:
        pass
    if "://" not in value:
        value = "https://" + value
    p = urlsplit(value)
    if p.scheme.lower() not in ("http", "https") or not p.hostname or p.username or p.password:
        raise ValueError("URL tidak valid atau mengandung kredensial")
    _ = p.port
    return urlunsplit((p.scheme.lower(), p.netloc, p.path or "/", p.query, ""))


def host(url):
    return (urlsplit(url).hostname or "").lower().rstrip(".")


def origin(url):
    p = urlsplit(url)
    return p.scheme.lower(), host(url), p.port or (443 if p.scheme == "https" else 80)


def safe_url(url):
    # Jangan tulis token/query/fragment ke laporan.
    p = urlsplit(url)
    return urlunsplit((p.scheme, p.netloc, p.path, "", ""))


class HTMLInfo(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.refs, self.generators = [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        for key in ("href", "src", "action"):
            if a.get(key):
                self.refs.append(a[key])
        if tag == "meta" and a.get("name", "").lower() == "generator":
            self.generators.append(a.get("content", ""))


class Report:
    def __init__(self, target):
        self.target = safe_url(target)
        self.rows = {}

    def row(self, url):
        # Pisah origin: HTTP/HTTPS atau port berbeda tidak digabung.
        p = urlsplit(url)
        key = f"{p.scheme}://{p.netloc}"
        if key not in self.rows:
            self.rows[key] = {
                "input_url": self.target, "observed_origin": key,
                "roles": set(), "statuses": set(), "server": set(),
                "php_versions": set(), "php_signals": {},
                "tech": defaultdict(dict), "evidence": set(), "errors": set(),
                "responses": 0, "observed_urls": set(),
            }
        return self.rows[key]

    def signal(self, row, group, score, evidence, tech=None):
        signals = row["tech"][tech] if tech else row["php_signals"]
        signals[group] = max(signals.get(group, 0), score)
        row["evidence"].add(evidence)

    def inspect(self, url, status, headers, body="", role="document"):
        row = self.row(url)
        row["responses"] += 1
        row["observed_urls"].add(safe_url(url))
        row["roles"].add(role)
        row["statuses"].add(str(status))
        h = {k.lower(): str(v) for k, v in headers.items()}
        if h.get("server"):
            row["server"].add(h["server"][:200])
        where = safe_url(url)
        for name in ("x-powered-by", "server"):
            value = h.get(name, "")
            m = re.search(r"\bPHP(?:[/\s]+(\d+(?:\.\d+){1,3}))?\b", value, re.I)
            if m:
                self.signal(row, "php_header", 95, f"{where}: {name}={value[:200]}")
                if m.group(1):
                    row["php_versions"].add(m.group(1))
        # Hanya nama cookie, tidak menyimpan nilainya.
        names = re.findall(r"(?:^|[\n,])\s*([^=;,\s]+)=", h.get("set-cookie", ""))
        for name in names:
            low = name.lower()
            if low == "phpsessid":
                self.signal(row, "php_cookie", 70, f"{where}: cookie PHPSESSID")
            if low in COOKIE_RULES:
                tech, score = COOKIE_RULES[low]
                self.signal(row, "cookie", score, f"{where}: cookie {name}", tech)
        if re.search(r"\.php(?:[0-9])?$", urlsplit(url).path, re.I):
            self.signal(row, "php_extension", 35, f"{where}: observed PHP-style URL (not proof of execution)")
        # Body hanya dianalisis sebagai HTML jika content-type sesuai.
        if "html" in h.get("content-type", "").lower() and body:
            parser = HTMLInfo()
            try:
                parser.feed(body)
            except Exception:
                pass
            refs = set()
            for ref in parser.refs:
                try:
                    absolute = urljoin(url, ref)
                    if origin(absolute) == origin(url) and re.search(r"\.php(?:[0-9])?(?:/|$)", urlsplit(absolute).path, re.I):
                        refs.add(safe_url(absolute))
                except ValueError:
                    continue
            if refs:
                self.signal(row, "php_extension", 35,
                            f"{where}: same-origin PHP references: {', '.join(sorted(refs)[:5])}")
            for tech, patterns in RULES.items():
                if any(re.search(pattern, body, re.I) for pattern in patterns):
                    self.signal(row, "html_signature", 65, f"{where}: specific HTML signature {tech}", tech)
            generators = parser.generators
        else:
            generators = []
        generators += [h.get("x-generator", "")]
        for gen in generators:
            for tech, pattern in GENERATORS.items():
                if re.match(r"\s*" + pattern + r"\b", gen, re.I):
                    self.signal(row, "generator", 85, f"{where}: generator {gen[:160]}", tech)
        # Composer hanya diperiksa jika URL tersebut memang diobservasi.
        if urlsplit(url).path.endswith(("/composer.json", "/composer.lock")) and status == 200:
            try:
                obj = json.loads(body)
                valid = isinstance(obj, dict) and (
                    isinstance(obj.get("packages"), list) or
                    any(isinstance(obj.get(k), dict) for k in ("require", "require-dev", "autoload")))
                if valid:
                    self.signal(row, "composer", 65, f"{where}: Composer-like JSON structure; verify manually")
            except (ValueError, TypeError):
                pass

    @staticmethod
    def score(signals):
        values = sorted(signals.values(), reverse=True)
        # Indikator berulang dalam kategori yang sama tidak menambah skor.
        return min(99, values[0] + min(10, sum(values[1:]) // 5)) if values else 0

    def export(self):
        output = []
        for row in self.rows.values():
            techs = {name: self.score(signals) for name, signals in row["tech"].items()}
            signals = dict(row["php_signals"])
            if techs:
                signals["php_ecosystem"] = max(techs.values())
            score = self.score(signals)
            detection = "detected" if score >= 80 else "suspected" if score else "unknown"
            if not row["responses"]:
                detection = "error"
            output.append({
                "input_url": row["input_url"], "observed_origin": row["observed_origin"],
                "roles": ";".join(sorted(row["roles"])),
                "status_codes": ";".join(sorted(row["statuses"])),
                "observed_urls": ";".join(sorted(row["observed_urls"])),
                "server": ";".join(sorted(row["server"])),
                "php_detection": detection, "php_confidence": score,
                "confidence_label": "high" if score >= 80 else "medium" if score >= 50 else "low" if score else "none",
                "php_versions_reported": ";".join(sorted(row["php_versions"])),
                "technologies_confidence": json.dumps(techs, ensure_ascii=False, sort_keys=True),
                "evidence": " | ".join(sorted(row["evidence"])),
                "errors": " | ".join(sorted(row["errors"])),
            })
        return output


def permitted(url, exact, suffixes):
    try:
        p = urlsplit(url)
        if p.scheme not in ("http", "https") or p.username or p.password:
            return False
        name = host(url)
        return name in exact or any(name == s or name.endswith("." + s) for s in suffixes)
    except ValueError:
        return False


def static_scan(target, args, exact, suffixes):
    report = Report(target)
    current = target
    with requests.Session() as session:
        session.headers["User-Agent"] = UA
        for _ in range(8):
            if not permitted(current, exact, suffixes):
                report.row(target)["errors"].add("Redirect outside allowlist blocked")
                break
            try:
                with session.get(current, timeout=args.timeout, verify=not args.insecure,
                                 allow_redirects=False, stream=True) as response:
                    chunks, size = [], 0
                    for chunk in response.iter_content(16384):
                        chunks.append(chunk)
                        size += len(chunk)
                        if size >= MAX_BODY:
                            break
                    body = b"".join(chunks)[:MAX_BODY].decode(response.encoding or "utf-8", errors="replace")
                    headers = dict(response.headers)
                    headers["Set-Cookie"] = "\n".join(response.raw.headers.getlist("Set-Cookie"))
                    report.inspect(current, response.status_code, headers, body)
                    if response.status_code in (301, 302, 303, 307, 308) and response.headers.get("Location"):
                        current = urljoin(current, response.headers["Location"])
                        continue
                    break
            except requests.RequestException as exc:
                report.row(current)["errors"].add(f"{type(exc).__name__}: {exc}")
                break
        else:
            report.row(target)["errors"].add("Redirect limit reached")
    return report


async def browser_scan(browser, target, report, args, exact, suffixes):
    context = await browser.new_context(ignore_https_errors=args.insecure,
                                        service_workers="block", user_agent=UA,
                                        accept_downloads=False)
    pending, seen = set(), set()
    count = 0

    async def route_handler(route):
        nonlocal count
        req = route.request
        if not permitted(req.url, exact, suffixes):
            report.row(target)["errors"].add("Browser blocked out-of-scope requests")
            await route.abort()
        elif req.method not in ("GET", "HEAD", "OPTIONS"):
            report.row(target)["errors"].add("Browser blocked non-read-only methods; API coverage may be incomplete")
            await route.abort()
        elif req.resource_type in ("image", "media", "font") or count >= args.max_requests:
            await route.abort()
        else:
            count += 1
            await route.continue_()

    async def inspect_response(response):
        if not permitted(response.url, exact, suffixes):
            return
        key = (response.url, response.status)
        if key in seen:
            return
        seen.add(key)
        try:
            headers = await response.all_headers()
            kind = response.request.resource_type
            body = ""
            content_type = headers.get("content-type", "").lower()
            # Tetap periksa header semua respons; body hanya document/API teks.
            if kind in ("document", "xhr", "fetch") and any(t in content_type for t in ("html", "json", "text/plain")):
                length = headers.get("content-length", "")
                if not length.isdigit() or int(length) <= MAX_BODY:
                    try:
                        body = (await asyncio.wait_for(response.body(), timeout=args.timeout))[:MAX_BODY].decode("utf-8", errors="replace")
                    except Exception:
                        pass
            report.inspect(response.url, response.status, headers, body,
                           "api" if kind in ("xhr", "fetch") else kind)
        except Exception as exc:
            report.row(response.url)["errors"].add("Response capture: " + type(exc).__name__)

    def schedule(response):
        task = asyncio.create_task(inspect_response(response))
        pending.add(task)
        task.add_done_callback(pending.discard)

    try:
        await context.route("**/*", route_handler)
        page = await context.new_page()
        page.on("response", schedule)
        try:
            await page.goto(target, wait_until="domcontentloaded", timeout=int(args.timeout * 1000))
            await page.wait_for_timeout(int(args.wait * 1000))
        except Exception as exc:
            report.row(target)["errors"].add(f"Browser navigation: {type(exc).__name__}: {exc}")
        if pending:
            done, remaining = await asyncio.wait(list(pending), timeout=args.timeout)
            for task in remaining:
                task.cancel()
            if remaining:
                await asyncio.gather(*remaining, return_exceptions=True)
    finally:
        await context.close()


def domain_entry(value):
    """Allowlist berisi domain, bukan URL/path atau wildcard bebas."""
    value = value.strip().lower().rstrip(".")
    if value.startswith("*."):
        value = value[2:]
    if not value or any(c in value for c in "/:@?# "):
        raise ValueError("Gunakan domain saja, misalnya example.co.id")
    value = value.encode("idna").decode("ascii")
    if len(value) > 253 or any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
                               for label in value.split(".")):
        raise ValueError("Domain allowlist tidak valid")
    return value


def scan_with_fallback(target, args, exact, suffixes):
    report = static_scan(target, args, exact, suffixes)
    chosen = target
    # Fallback hanya untuk input tanpa skema dan jika tidak ada respons HTTP.
    # HTTP 401/403/404/500 adalah respons valid, bukan kegagalan koneksi.
    if target in args.auto_https_targets and not any(r["responses"] for r in report.rows.values()):
        parsed = urlsplit(target)
        chosen = urlunsplit(("http", parsed.netloc, parsed.path, parsed.query, ""))
        print(f"[~] HTTPS gagal, mencoba HTTP: {safe_url(chosen)}", flush=True)
        fallback = static_scan(chosen, args, exact, suffixes)
        for row in fallback.rows.values():
            row["input_url"] = report.target
            row["evidence"].add("HTTP fallback attempted after HTTPS connection/TLS failure")
        report.rows.update(fallback.rows)
    return report, chosen


async def run(args, targets):
    exact = {host(t) for t in targets}
    exact.update(x.lower().rstrip(".") for x in args.allow_host)
    suffixes = set(args.allow_domain)
    semaphore = asyncio.Semaphore(args.workers)
    browser = manager = None
    if args.browser:
        try:
            from playwright.async_api import async_playwright
            manager = await async_playwright().start()
            browser = await manager.chromium.launch(headless=True)
        except Exception:
            if manager:
                await manager.stop()
            raise RuntimeError("Browser belum siap: pip install playwright && python -m playwright install chromium")

    async def one(target):
        async with semaphore:
            report, chosen = await asyncio.to_thread(scan_with_fallback, target, args, exact, suffixes)
            if browser:
                await browser_scan(browser, chosen, report, args, exact, suffixes)
            rows = report.export()
            print(f"[+] {safe_url(target)} -> {len(rows)} origin", flush=True)
            return rows

    try:
        groups = await asyncio.gather(*(one(t) for t in targets))
        return [row for group in groups for row in group]
    finally:
        if browser:
            await browser.close()
        if manager:
            await manager.stop()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("input", help="File URL/IP, satu per baris; # untuk komentar")
    p.add_argument("-o", "--output", default="php_fingerprint_v3.csv")
    p.add_argument("--browser", action="store_true", help="Tangkap respons browser/API")
    p.add_argument("--allow-host", action="append", default=[], help="Host tambahan yang diizinkan; dapat diulang")
    p.add_argument("--allow-domain", action="append", default=[], help="Izinkan domain DAN seluruh subdomainnya; dapat diulang")
    p.add_argument("--allowlist", help="File domain tambahan yang diizinkan, satu per baris")
    p.add_argument("--workers", type=int, default=3)
    p.add_argument("--timeout", type=float, default=12)
    p.add_argument("--wait", type=float, default=5, help="Detik observasi setelah DOM siap")
    p.add_argument("--max-requests", type=int, default=100, help="Batas request browser per target")
    p.add_argument("--insecure", action="store_true", help="Abaikan validasi TLS secara eksplisit")
    args = p.parse_args()
    if args.workers < 1 or args.timeout <= 0 or args.wait < 0 or args.max_requests < 1:
        p.error("Nilai workers/timeout/max-requests harus positif; wait tidak negatif")
    try:
        args.allow_domain = [domain_entry(x) for x in args.allow_domain]
        if args.allowlist:
            with open(args.allowlist, encoding="utf-8-sig") as f:
                for line in f:
                    entry = line.split("#", 1)[0].strip()
                    if entry:
                        args.allow_domain.append(domain_entry(entry))
    except (OSError, ValueError) as exc:
        p.error(f"Allowlist: {exc}")
    args.auto_https_targets = set()
    explicit_targets = set()
    targets = []
    with open(args.input, encoding="utf-8-sig") as f:
        for n, line in enumerate(f, 1):
            try:
                value = normalize(line)
            except ValueError as exc:
                p.error(f"Baris {n}: {exc}")
            if value:
                if "://" not in line.strip():
                    args.auto_https_targets.add(value)
                else:
                    explicit_targets.add(value)
                if value not in targets:
                    targets.append(value)
    # Jika URL sama ditulis juga dengan HTTPS eksplisit, jangan downgrade.
    args.auto_https_targets.difference_update(explicit_targets)
    if not targets:
        p.error("Input kosong")
    rows = asyncio.run(run(args, targets))
    # Mitigasi formula injection saat CSV dibuka di spreadsheet.
    def safe_cell(value):
        value = str(value)
        return "'" + value if value.lstrip().startswith(("=", "+", "-", "@")) else value
    with open(args.output, "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows({k: safe_cell(v) for k, v in row.items()} for row in rows)
    print(f"Selesai: {args.output} ({len(rows)} baris). Confidence = heuristik, bukan probabilitas.")


if __name__ == "__main__":
    main()
