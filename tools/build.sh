#!/bin/sh
set -eu
set -f
BASE=$(cd "$(dirname "$0")/.." && pwd)
OUT=$BASE/dist
mkdir -p "$OUT"
stage=$(mktemp -d "${TMPDIR:-/tmp}/axdhcp-build.XXXXXX")
cleanup() { rm -rf "$stage/axdhcp"; rmdir "$stage"; }
trap cleanup 0
trap 'exit 1' HUP INT TERM
mkdir "$stage/axdhcp"
for item in backend config docs tools web adapters tests README.md VERSION install.sh uninstall.sh; do cp -R "$BASE/$item" "$stage/axdhcp/"; done
rm -f "$stage/axdhcp/config/axdhcp.conf"
find "$stage/axdhcp" -type d -name __pycache__ -prune -exec rm -r '{}' ';'
find "$stage/axdhcp" -type f -name '*.pyc' -delete
find "$stage/axdhcp" -type f -name '.DS_Store' -delete
find "$stage/axdhcp" -type f -name '*.sh' -exec chmod 755 '{}' ';'
version=$(cat "$BASE/VERSION")
COPYFILE_DISABLE=1 tar -czf "$OUT/axdhcp-$version-review.tar.gz" -C "$stage" axdhcp
if which sha256sum >/dev/null 2>&1; then
    sha256sum "$OUT/axdhcp-$version-review.tar.gz"
else shasum -a 256 "$OUT/axdhcp-$version-review.tar.gz"; fi
printf 'Standalone review package; no .valid marker and no KoolShare offline compatibility claim.\n'
