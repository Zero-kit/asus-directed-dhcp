#!/bin/sh
# Read-only, selected DHCP directives only. No executable config loading.
set -f
printf 'AXDHCP_CHECK_BEGIN\n只读检查：不启动 DHCP，不修改网络。\n'
for key in productid sw_mode re_mode wlc_mode wlc_band lan_ifname lan_ifnames wl0_ifname wl1_ifname wl1_vifs; do
    printf '%s=%s\n' "$key" "$(nvram get "$key" 2>/dev/null)"
done
BASE=$(cd "$(dirname "$0")/.." && pwd)
printf '\n开机启动检查（只读）\n'
awk -F= '$1=="enabled" || $1=="autostart" {print}' "$BASE/config/axdhcp.conf" 2>/dev/null
printf 'jffs2_scripts=%s\n' "$(nvram get jffs2_scripts 2>/dev/null)"
for hook in /koolshare/init.d/V99axdhcp.sh /koolshare/init.d/S99axdhcp.sh /jffs/scripts/services-start /koolshare/bin/ks-services-start.sh; do
    if [ -e "$hook" ]; then ls -ldn "$hook"; else printf 'missing: %s\n' "$hook"; fi
done
bridge=$(awk -F= '$1=="bridge" {print $2}' "$BASE/config/axdhcp.conf" 2>/dev/null)
case $bridge in ''|-*|*[!A-Za-z0-9_.-]*) bridge=br0;; esac
ip -4 addr show dev "$bridge"
ip route show default
printf '\n接口识别（只读）\n'
sh "$BASE/backend/discover.sh"
printf 'ip_forward='; cat /proc/sys/net/ipv4/ip_forward
show_directives() {
    awk '/^[ \t]*#/ {next}
    /^[ \t]*(conf-dir|conf-file|interface|except-interface|no-dhcp-interface|bind-interfaces|bind-dynamic|dhcp-range|dhcp-ignore|dhcp-authoritative|enable-ra|enable-tftp)(=|[ \t]|$)/ {print}
    /^[ \t]*dhcp-script(=|[ \t]|$)/ {print "dhcp-script=<present, withheld>"}' "$1"
}
printf '\n系统 DHCP 与包含指令\n'
if [ -r /etc/dnsmasq.conf ]; then
    show_directives /etc/dnsmasq.conf
    awk '/^[ \t]*conf-(dir|file)=/ {sub(/^[ \t]*/, ""); print}' /etc/dnsmasq.conf |
    while IFS= read -r directive; do
        include_path=${directive#*=}; include_path=${include_path%%,*}
        case $include_path in /*) :;; *) printf 'BLOCKED: relative include\n'; continue;; esac
        case $directive in
            conf-file=*) printf '\n文件：%s\n' "$include_path"; [ ! -r "$include_path" ] || show_directives "$include_path";;
            conf-dir=*)
                printf '\n目录：%s\n' "$include_path"
                [ -d "$include_path" ] || { printf 'BLOCKED: missing include directory\n'; continue; }
                (
                    set +f
                    count=0
                    for file in "$include_path"/* "$include_path"/.[!.]*; do
                        [ -f "$file" ] || continue
                        count=$((count+1))
                        [ "$count" -le 40 ] || { printf 'BLOCKED: listing truncated\n'; break; }
                        printf '\n文件：%s\n' "$file"
                        show_directives "$file"
                    done
                );;
        esac
    done
else printf 'BLOCKED: system configuration unreadable\n'; fi
printf '\n过滤规则（只读）\n'
for chain in INPUT FORWARD OUTPUT; do ebtables -t filter -L "$chain" --Lx; done
printf '\n包含配置只枚举第一层，扩展名选择与嵌套包含需审查。\n真实过滤与 raw socket 路径仍未验证。\nAXDHCP_CHECK_END\n'
