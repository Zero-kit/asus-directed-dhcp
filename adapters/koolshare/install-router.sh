#!/bin/sh
set -eu
set -f
umask 077
SRC=$(cd "$(dirname "$0")" && pwd)
DEST=/koolshare/axdhcp
fail() { printf 'AXDHCP_INSTALL_REJECTED: %s\n' "$1" >&2; exit 1; }
[ -r /proc/self/status ] && awk '$1=="Uid:" {found=1; uid=$3} END {exit (found && uid=="0" ? 0 : 1)}' /proc/self/status || fail 'root required'
for tool in awk jq curl head dbus mkdir rmdir ip nvram wl ebtables dnsmasq readlink nohup; do which "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"; done
for dir in /koolshare/scripts /koolshare/webs /koolshare/res /koolshare/init.d; do [ -d "$dir" ] || fail "missing framework directory: $dir"; done
for path in "$DEST" /koolshare/scripts/axdhcp_api.sh /koolshare/scripts/uninstall_axdhcp.sh /koolshare/webs/Module_axdhcp.asp /koolshare/res/axdhcp /koolshare/init.d/V99axdhcp.sh /koolshare/init.d/S99axdhcp.sh; do
    [ ! -L "$path" ] || fail "refusing symlink target: $path"
done
for asset_name in app.js presentation.js style.css router-style.css router-transport.js index.html; do
    [ -f "$SRC/res/axdhcp/$asset_name" ] || fail "package resource missing: $asset_name"
done
sh "$SRC/backend/axdhcp.sh" validate "$SRC/config/axdhcp.conf.example" >/dev/null || fail 'package configuration invalid'
# Use the corrected backend for shutdown; old scripts collide with /tmp/axdhcp
# (this package's extraction directory). Only inspect legacy lifecycle markers.
for runtime in /tmp/axdhcp /tmp/axdhcp-runtime; do
    active=0
    for marker in generation rules.owned dns.identity dns.launching dnsmasq.pid boot.pending; do
        [ ! -e "$runtime/$marker" ] || active=1
    done
    if [ "$active" = 1 ]; then
        printf '停止已有 axdhcp 事务：%s\n' "$runtime"
        AXDHCP_RUN="$runtime" sh "$SRC/backend/axdhcp.sh" stop || fail 'backend stop failed; existing files preserved'
    fi
done
backup=/koolshare/.axdhcp-install.$$
mkdir -m 700 "$backup"
slot_path() {
    case $1 in
        backend) printf '%s\n' "$DEST";;
        api) printf '/koolshare/scripts/axdhcp_api.sh\n';;
        uninstall) printf '/koolshare/scripts/uninstall_axdhcp.sh\n';;
        page) printf '/koolshare/webs/Module_axdhcp.asp\n';;
        assets) printf '/koolshare/res/axdhcp\n';;
        boot) printf '/koolshare/init.d/V99axdhcp.sh\n';;
        legacyboot) printf '/koolshare/init.d/S99axdhcp.sh\n';;
    esac
}
committed=0
install_started=0
cleanup() {
    [ "$committed" = 0 ] || return 0
    for slot in backend api uninstall page assets boot legacyboot; do
        target=$(slot_path "$slot")
        if [ "$install_started" = 1 ] && [ -e "$target" ]; then
            mv "$target" "$backup/failed-$slot" || { printf 'Recovery required: %s\n' "$target" >&2; continue; }
        fi
        [ ! -e "$backup/$slot" ] || mv "$backup/$slot" "$target" || :
    done
    for key in name title description version install; do
        [ ! -f "$backup/dbus-$key" ] || {
            value=$(cat "$backup/dbus-$key")
            if [ -n "$value" ]; then dbus set "softcenter_module_axdhcp_$key=$value" || :
            else dbus remove "softcenter_module_axdhcp_$key" || :; fi
        }
    done
    printf '安装未完成，旧文件已尝试恢复；备份位于 %s\n' "$backup" >&2
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
for key in name title description version install; do
    dbus get "softcenter_module_axdhcp_$key" > "$backup/dbus-$key"
done
for slot in backend api uninstall page assets boot legacyboot; do
    target=$(slot_path "$slot")
    [ ! -e "$target" ] || mv "$target" "$backup/$slot"
done
install_started=1
mkdir -m 700 "$DEST"
cp -R "$SRC/backend" "$SRC/config" "$SRC/docs" "$DEST/"
cp "$SRC/version" "$DEST/VERSION"
cp "$DEST/config/axdhcp.conf.example" "$DEST/config/axdhcp.conf"
if [ -f "$backup/backend/config/axdhcp.conf" ]; then
    # Retain user settings, but an integration upgrade must never arm DHCP.
    sed -e 's/^enabled=.*/enabled=0/' -e 's/^autostart=.*/autostart=0/' "$backup/backend/config/axdhcp.conf" > "$DEST/config/axdhcp.conf"
fi
sh "$DEST/backend/axdhcp.sh" validate "$DEST/config/axdhcp.conf" >/dev/null
chmod 700 "$DEST/backend/axdhcp.sh"
cp "$SRC/scripts/axdhcp_api.sh" /koolshare/scripts/axdhcp_api.sh
cp "$SRC/uninstall.sh" /koolshare/scripts/uninstall_axdhcp.sh
chmod 755 /koolshare/scripts/axdhcp_api.sh /koolshare/scripts/uninstall_axdhcp.sh
cp "$SRC/scripts/axdhcp_boot.sh" /koolshare/init.d/V99axdhcp.sh
chmod 755 /koolshare/init.d/V99axdhcp.sh
mkdir -m 755 /koolshare/res/axdhcp
# set -f deliberately disables glob expansion throughout this script. Keep the
# allowlist explicit so a missing asset fails closed on BusyBox too.
for asset_name in app.js presentation.js style.css router-style.css router-transport.js index.html; do
    asset="$SRC/res/axdhcp/$asset_name"
    [ -f "$asset" ] || fail "resource file missing: $asset_name"
    cp "$asset" "/koolshare/res/axdhcp/$asset_name" || fail "cannot copy resource: $asset_name"
    chmod 644 "/koolshare/res/axdhcp/$asset_name" 2>/dev/null || :
done
cp "$SRC/webs/Module_axdhcp.asp" /koolshare/webs/Module_axdhcp.asp
chmod 644 /koolshare/webs/Module_axdhcp.asp
dbus set 'softcenter_module_axdhcp_name=axdhcp'
dbus set 'softcenter_module_axdhcp_title=华硕定向 DHCP'
dbus set 'softcenter_module_axdhcp_description=双频定向 DHCP，可选开机运行'
dbus set "softcenter_module_axdhcp_version=$(cat "$SRC/version")"
dbus set 'softcenter_module_axdhcp_install=1'
committed=1
case "$backup" in /koolshare/.axdhcp-install.[0-9]*)
    [ -d "$backup" ] && [ ! -L "$backup" ] && rm -rf "$backup" || printf '安装成功，临时安装文件清理失败：%s\n' "$backup" >&2;;
esac
printf 'AXDHCP 安装完成：DHCP 和开机自动运行默认关闭，请打开插件页面设置。\n'
