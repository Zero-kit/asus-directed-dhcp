#!/bin/sh
set -eu
set -f
BASE=/koolshare/axdhcp
[ -d "$BASE" ] && [ ! -L "$BASE" ] || exit 1
sh "$BASE/backend/axdhcp.sh" stop || { printf 'Stop failed; plugin retained for recovery\n' >&2; exit 1; }
backup="/koolshare/axdhcp.retired.$(date +%s).$$"
mv "$BASE" "$backup"
[ ! -e /koolshare/init.d/V99axdhcp.sh ] || mv /koolshare/init.d/V99axdhcp.sh "$backup/boot-hook.sh"
[ ! -e /koolshare/init.d/S99axdhcp.sh ] || mv /koolshare/init.d/S99axdhcp.sh "$backup/legacy-boot-hook.sh"
rm -f /koolshare/scripts/axdhcp_api.sh /koolshare/webs/Module_axdhcp.asp
[ ! -e /koolshare/res/axdhcp ] || mv /koolshare/res/axdhcp "$backup/web-assets"
for key in name title description version install; do dbus remove "softcenter_module_axdhcp_$key"; done
rm -f /koolshare/scripts/uninstall_axdhcp.sh
printf 'Uninstalled. Configuration and backend preserved at %s\n' "$backup"
