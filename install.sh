#!/bin/sh
set -f
umask 077
SRC=$(cd "$(dirname "$0")" && pwd)
if [ "${1:-}" != --standalone ]; then
    printf 'Stage 1 is a standalone review package. KoolShare offline installation is gated.\nUsage: sh install.sh --standalone\n' >&2
    exit 78
fi
[ -r /proc/self/status ] && awk '$1=="Uid:" { found=1; uid=$3 } END { exit (found && uid=="0" ? 0 : 1) }' /proc/self/status || { printf 'Root required for /jffs installation\n' >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || exit 1
DEST=/jffs/axdhcp
[ ! -e "$DEST" ] && [ ! -L "$DEST" ] || { printf 'Existing /jffs/axdhcp preserved; stop and review before upgrade\n' >&2; exit 1; }
mkdir -m 700 "$DEST" || exit 1
for item in backend config docs tools web adapters README.md VERSION uninstall.sh; do
    cp -R "$SRC/$item" "$DEST/" || { printf 'Partial file installation; no network changed\n' >&2; exit 1; }
done
cp "$DEST/config/axdhcp.conf.example" "$DEST/config/axdhcp.conf" || exit 1
chmod 700 "$DEST/backend/axdhcp.sh" "$DEST/tools/collect-env.sh" "$DEST/tools/probe-rules.sh" "$DEST/uninstall.sh"
printf 'Installed disabled standalone backend in /jffs/axdhcp; no service, dbus registration, web publication or startup hook was created.\n'
