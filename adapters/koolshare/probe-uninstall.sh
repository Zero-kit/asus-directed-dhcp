#!/bin/sh
# Remove only the diagnostic plugin's exact files and metadata.
set -f
rm -f /koolshare/webs/Module_axdhcp_probe.asp || exit 1
for key in name title description version install; do
    dbus remove "softcenter_module_axdhcp_probe_$key" || exit 1
done
rm -f /koolshare/scripts/uninstall_axdhcp_probe.sh || exit 1
printf 'AXDHCP environment-check plugin removed; no DHCP or network settings changed.\n'
