#!/usr/bin/env bash
# Aleph for Grimmory modification, 2026-11-28: Aleph's Grimmory code against a
# real Grimmory in Docker, with no e-reader. Needs docker (with compose),
# curl, python3, zip, luajit, lua-socket and lua-cjson
# (Debian/Ubuntu: apt install luajit lua-socket lua-cjson zip).
#
#   tests/e2e/run.sh            start Grimmory, run the checks, stop it
#   KEEP=1 tests/e2e/run.sh     leave Grimmory running (http://localhost:6061)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
port="${GRIMMORY_PORT:-6061}"
base="http://localhost:$port"
work="$here/work"
compose() { docker compose -p aleph-e2e -f "$here/docker-compose.yml" "$@"; }

cleanup() {
    if [ -z "${KEEP:-}" ]; then compose down -v >/dev/null 2>&1 || true; rm -rf "$work"; fi
}
trap cleanup EXIT

rm -rf "$work"; mkdir -p "$work/books" "$work/epub"
# A small EPUB of our own (title, author, two paragraphs).
python3 - "$work/epub" <<'PY'
import os, sys
d = sys.argv[1]
os.makedirs(d + "/META-INF"); os.makedirs(d + "/OEBPS")
open(d + "/mimetype", "w").write("application/epub+zip")
open(d + "/META-INF/container.xml", "w").write('<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
open(d + "/OEBPS/content.opf", "w").write('<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:isbn:9780000000002</dc:identifier><dc:title>Aleph Test Book</dc:title><dc:creator>Ada Tester</dc:creator><dc:language>en</dc:language><meta property="dcterms:modified">2026-11-28T00:00:00Z</meta></metadata><manifest><item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="c1"/></spine></package>')
open(d + "/OEBPS/nav.xhtml", "w").write('<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Nav</title></head><body><nav epub:type="toc"><ol><li><a href="chapter1.xhtml">One</a></li></ol></nav></body></html>')
open(d + "/OEBPS/chapter1.xhtml", "w").write('<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head><body><p>Hello world, this is the first paragraph.</p><p>And here comes the second one.</p></body></html>')
PY
(cd "$work/epub" && zip -X -q -0 "$work/books/Aleph Test Book.epub" mimetype && zip -X -q -r "$work/books/Aleph Test Book.epub" META-INF OEBPS)
# KOReader's partial MD5 (util.partialMD5), the id Grimmory knows a book by.
hash=$(python3 - "$work/books/Aleph Test Book.epub" <<'PY'
import hashlib, sys
m = hashlib.md5(); f = open(sys.argv[1], "rb")
for i in range(-1, 11):
    off = (1024 << ((2 * i) & 31)) & 0xffffffff
    f.seek(off); s = f.read(1024)
    if not s: break
    m.update(s)
print(m.hexdigest())
PY
)

echo "Starting Grimmory on $base..."
compose up -d >/dev/null
for i in $(seq 1 120); do
    if curl -sf "$base/api/v1/setup/status" >/dev/null 2>&1; then break; fi
    sleep 3
    if [ "$i" = 120 ]; then echo "Grimmory did not start"; compose logs grimmory | tail -50; exit 1; fi
done
user=alex; pass=aleph-e2e-pass
curl -sf -X POST "$base/api/v1/setup" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$user\",\"email\":\"alex@example.org\",\"name\":\"Alex\",\"password\":\"$pass\"}" >/dev/null || true
token=$(curl -sf -X POST "$base/api/v1/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$user\",\"password\":\"$pass\"}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["accessToken"])')
curl -sf -X POST "$base/api/v1/libraries" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    -d '{"name":"Test","paths":[{"path":"/books"}],"watch":false}' >/dev/null
echo "Waiting for the book to be scanned..."
for i in $(seq 1 60); do
    n=$(curl -sf "$base/api/v1/books" -H "Authorization: Bearer $token" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' || echo 0)
    [ "$n" -ge 1 ] && break
    sleep 2
    if [ "$i" = 60 ]; then echo "The book was not scanned"; exit 1; fi
done

cd "$root"
ALEPH_TEST_DIR="$work" luajit tests/e2e/grimmory_e2e.lua "$base" "$user" "$pass" "$work/books/Aleph Test Book.epub" "$work/epub" "$hash"
