#!/bin/sh
set -f
[ "${1:-}" = --standalone ] || { printf 'Usage: sh /jffs/axdhcp/uninstall.sh --standalone\n' >&2; exit 1; }
BASE=$(cd "$(dirname "$0")" && pwd)
[ "$BASE" = /jffs/axdhcp ] && [ ! -L /jffs/axdhcp ] || { printf 'Expected exact standalone installation path\n' >&2; exit 1; }
sh "$BASE/backend/axdhcp.sh" stop || { printf 'Stop failed; installation preserved for recovery\n' >&2; exit 1; }
backup="/jffs/axdhcp.retired.$(date +%s).$$"
mv /jffs/axdhcp "$backup" || exit 1
printf 'Stopped and moved installation to %s; configuration and files remain recoverable. Runtime logs remain in /tmp/axdhcp until reboot.\n' "$backup"
