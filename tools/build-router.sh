#!/bin/sh
set -eu
set -f
BASE=$(cd "$(dirname "$0")/.." && pwd)
stage=$(mktemp -d "${TMPDIR:-/tmp}/axdhcp-router-build.XXXXXX")
cleanup() { rm -rf "$stage/axdhcp"; rmdir "$stage"; }
trap cleanup 0
trap 'exit 1' HUP INT TERM
version=0.5.6-interfaces
display_version=${version%%-*}
mkdir -p "$stage/axdhcp/scripts" "$stage/axdhcp/webs" "$stage/axdhcp/res/axdhcp" "$BASE/dist"
cp -R "$BASE/backend" "$BASE/config" "$stage/axdhcp/"
mkdir "$stage/axdhcp/docs"
for doc in integration-package.md interfaces.md recovery.md; do
    cp "$BASE/docs/$doc" "$stage/axdhcp/docs/"
done
rm -f "$stage/axdhcp/config/axdhcp.conf"
cp "$BASE/adapters/koolshare/install-router.sh" "$stage/axdhcp/install.sh"
cp "$BASE/adapters/koolshare/uninstall-router.sh" "$stage/axdhcp/uninstall.sh"
cp "$BASE/adapters/koolshare/router-api.sh" "$stage/axdhcp/scripts/axdhcp_api.sh"
cp "$BASE/adapters/koolshare/boot-router.sh" "$stage/axdhcp/scripts/axdhcp_boot.sh"
cp "$BASE/adapters/koolshare/probe.valid" "$stage/axdhcp/.valid"
printf '%s\n' "$version" > "$stage/axdhcp/version"
cp "$BASE/web/style.css" "$BASE/web/app.js" "$BASE/web/presentation.js" "$BASE/adapters/koolshare/router-transport.js" "$stage/axdhcp/res/axdhcp/"
cp "$BASE/adapters/koolshare/router-style.css" "$stage/axdhcp/res/axdhcp/"
sed -e 's|<link rel="stylesheet" href="style.css">|<link rel="stylesheet" href="/res/axdhcp/style.css"><link rel="stylesheet" href="/res/axdhcp/router-style.css">|' \
    -e 's|<script src="app.js"></script>|<script src="/res/axdhcp/router-transport.js"></script><script src="/res/axdhcp/app.js"></script>|' \
    -e 's|src="presentation.js"|src="/res/axdhcp/presentation.js"|' \
    -e "s|0.1.1|$display_version|" -e 's|第一阶段 · 本地预览|软件中心|' \
    -e '/<div class="notice">/d' \
    "$BASE/web/index.html" > "$stage/axdhcp/res/axdhcp/index.html"
cp "$BASE/adapters/koolshare/Module_axdhcp.asp" "$stage/axdhcp/webs/Module_axdhcp.asp"
find "$stage/axdhcp" -type f -name '.DS_Store' -delete
find "$stage/axdhcp" -type f -name '*.sh' -exec chmod 755 '{}' ';'
COPYFILE_DISABLE=1 tar -czf "$BASE/dist/axdhcp-$version.tar.gz" -C "$stage" axdhcp
shasum -a 256 "$BASE/dist/axdhcp-$version.tar.gz"
printf 'Continuous package: manual start/stop and opt-in boot startup; install/upgrade defaults disabled. Hardware validation pending.\n'
