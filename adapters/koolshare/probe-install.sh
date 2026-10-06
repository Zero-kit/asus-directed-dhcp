#!/bin/sh
# Offline-package diagnostic with a static explanation page and uninstaller.
# No base.sh execution, startup hooks, or network mutations.
set -f
umask 077
SRC=$(cd "$(dirname "$0")" && pwd) || exit 1
fail() { printf 'AXDHCP_PROBE_REJECTED: %s\n' "$1" >&2; exit 1; }
# Some Asuswrt BusyBox builds omit the id applet. Read our effective UID from
# procfs instead of assuming id(1) exists.
is_root() {
    [ -r /proc/self/status ] || return 1
    awk '$1=="Uid:" { found=1; uid=$3 } END { exit (found && uid=="0" ? 0 : 1) }' /proc/self/status
}
is_root || fail 'requires router root installation context'
[ -d /koolshare ] && [ -f /koolshare/scripts/base.sh ] || fail 'KoolShare framework not found'
which nvram >/dev/null 2>&1 || fail 'nvram unavailable'
[ "$(nvram get productid)" = RT-AX86U ] || fail 'only RT-AX86U is in scope'
[ "$(uname -m)" = aarch64 ] || fail 'expected aarch64'
[ "$(uname -r)" = 4.1.52 ] || fail 'expected kernel 4.1.52'
[ -f "$SRC/scripts/axdhcp_probe_collect.sh" ] || fail 'collector missing'
[ -f "$SRC/webs/Module_axdhcp_probe.asp" ] && [ -f "$SRC/uninstall.sh" ] || fail 'page or uninstaller missing'
[ -d /koolshare/webs ] && [ -d /koolshare/scripts ] || fail 'framework directories missing'
which dbus >/dev/null 2>&1 || fail 'dbus unavailable'
for path in /koolshare/webs/Module_axdhcp_probe.asp /koolshare/scripts/uninstall_axdhcp_probe.sh; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail 'existing diagnostic installation preserved; uninstall it before retrying'
done
printf '\nAXDHCP_PROBE_BEGIN\n'
printf '华硕定向 DHCP：环境检查包；未安装 DHCP 服务。\n'
printf '请复制 BEGIN 至 END 的安装日志，分享前可遮蔽 SSID/MAC/BSSID。\n'
printf '\nShell identity\n'
ls -l /bin/sh
if which busybox >/dev/null 2>&1; then busybox | head -n 1; fi
sh "$SRC/scripts/axdhcp_probe_collect.sh" || fail 'collector failed; preserve the installation log'
printf '\nAXDHCP_PROBE_END\n'
cp "$SRC/uninstall.sh" /koolshare/scripts/uninstall_axdhcp_probe.sh || fail 'cannot install uninstaller'
chmod 755 /koolshare/scripts/uninstall_axdhcp_probe.sh || fail 'cannot set uninstaller permissions'
cp "$SRC/webs/Module_axdhcp_probe.asp" /koolshare/webs/Module_axdhcp_probe.asp || fail 'cannot install explanation page'
dbus set 'softcenter_module_axdhcp_probe_title=华硕定向 DHCP · 环境检查' || fail 'cannot set title'
dbus set 'softcenter_module_axdhcp_probe_description=环境采集与适配检查，未启用 DHCP' || fail 'cannot set description'
dbus set 'softcenter_module_axdhcp_probe_version=0.1.3' || fail 'cannot set version'
printf '环境检查结束。已安装说明页与卸载入口，没有启动 DHCP 或改变网络。\n'
printf '日志中的命令缺失或权限错误也请保留；本包不代表 DHCP 实机验证通过。\n'
exit 0
