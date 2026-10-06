#!/bin/sh
set -eu
BASE=$(cd "$(dirname "$0")/.." && pwd)
for script in backend/axdhcp.sh backend/check-env.sh backend/interfaces.sh backend/discover.sh tools/collect-env.sh tools/probe-rules.sh tools/build.sh tools/check.sh adapters/koolshare/axdhcp-api.sh adapters/koolshare/router-api.sh adapters/koolshare/boot-router.sh adapters/koolshare/install-router.sh adapters/koolshare/uninstall-router.sh tools/build-router.sh install.sh uninstall.sh; do
    sh -n "$BASE/$script"
done
sh "$BASE/backend/axdhcp.sh" validate "$BASE/config/axdhcp.conf.example" >/dev/null
node --check "$BASE/web/app.js"
node --check "$BASE/web/presentation.js"
node --check "$BASE/adapters/koolshare/router-transport.js"
node --check "$BASE/tools/preview.mjs"
if which shellcheck >/dev/null 2>&1; then
    shellcheck -s sh "$BASE/backend/axdhcp.sh" "$BASE/tools/collect-env.sh" "$BASE/tools/probe-rules.sh" "$BASE/install.sh" "$BASE/uninstall.sh" "$BASE/tools/build.sh" "$BASE/tools/check.sh" "$BASE/adapters/koolshare/axdhcp-api.sh"
else printf 'SKIP: ShellCheck unavailable\n'; fi
if which busybox >/dev/null 2>&1; then
    busybox sh -n "$BASE/backend/axdhcp.sh"
    busybox awk -f "$BASE/backend/validate.awk" "$BASE/config/axdhcp.conf.example" >/dev/null
else printf 'SKIP: BusyBox unavailable; actual firmware shell remains unverified\n'; fi
printf 'Available static checks passed; NOT hardware verification\n'
