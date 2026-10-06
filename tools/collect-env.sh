#!/bin/sh
# Read-only, allowlisted report. Redirect stdout to a file yourself if desired.
set -f
printf 'AXDHCP read-only environment report v1\n'
date -u
uname -m
uname -r
printf '\nAllowed NVRAM values (no global export)\n'
if which nvram >/dev/null 2>&1; then
    for key in productid model buildno extendno sw_mode re_mode wlc_mode wlc_band lan_ifname lan_ifnames wl0_ifname wl1_ifname wl1_vifs; do
        printf '%s=%s\n' "$key" "$(nvram get "$key")"
    done
fi
printf '\nRelevant binaries\n'
for tool in sh awk grep sed tr cksum readlink nohup ip brctl wl ebtables dnsmasq dbus httpdb skipd tcpdump; do which "$tool" 2>/dev/null || :; done
printf '\nSoftware-center layout (names and link targets only)\n'
for dir in /koolshare /koolshare/bin /koolshare/scripts /koolshare/webs /koolshare/res /koolshare/init.d /jffs/scripts; do
    if [ -d "$dir" ]; then
        printf '%s\n' "$dir"
        ls -ld "$dir"
        ls -1 "$dir" | head -n 100
    fi
done
printf '\nKnown framework versions (exact keys only)\n'
if which dbus >/dev/null 2>&1; then
    for key in softcenter_version softcenter_api softcenter_arch softcenter_module_softcenter_version; do printf '%s=%s\n' "$key" "$(dbus get "$key" 2>/dev/null)"; done
fi
printf '\nFramework files: metadata / checksum, not contents\n'
for path in /koolshare/scripts/base.sh /koolshare/res/softcenter.js /koolshare/webs/Module_Softcenter.asp /jffs/scripts/services-start /jffs/scripts/service-event /jffs/scripts/firewall-start /jffs/scripts/nat-start; do
    if [ -f "$path" ]; then
        ls -l "$path"
        if which cksum >/dev/null 2>&1; then cksum "$path"
        elif which md5sum >/dev/null 2>&1; then md5sum "$path"
        else printf 'SKIP: no checksum tool\n'; fi
    fi
done
printf '\nStartup link structure\n'
if [ -d /koolshare/init.d ]; then ls -l /koolshare/init.d | head -n 100; fi
printf '\nBridge / routes / link identities\n'
if which brctl >/dev/null 2>&1; then brctl show br0; fi
if which ip >/dev/null 2>&1; then ip -4 addr show dev br0; ip route show default; fi
for iface in br0 eth6 eth7 wl1.1; do
    printf '%s\n' "$iface"
    for key in address operstate carrier; do [ ! -r "/sys/class/net/$iface/$key" ] || { printf '%s=' "$key"; cat "/sys/class/net/$iface/$key"; }; done
    if [ "$iface" != br0 ] && which wl >/dev/null 2>&1; then wl -i "$iface" bssid 2>/dev/null; wl -i "$iface" ssid 2>/dev/null; fi
done
printf '\nForwarding / filtering (listing only)\n'
cat /proc/sys/net/ipv4/ip_forward 2>/dev/null
if which ebtables >/dev/null 2>&1; then
    ebtables -V
    for chain in INPUT FORWARD OUTPUT; do ebtables -t filter -L "$chain" --Lx; ebtables -t filter -L "$chain" --Lc; done
fi
printf '\nSystem dnsmasq: selected directives only\n'
if which dnsmasq >/dev/null 2>&1; then dnsmasq --version; fi
for path in /etc/dnsmasq.conf /tmp/etc/dnsmasq.conf; do
    if [ -r "$path" ]; then
        printf '%s\n' "$path"
        grep -E '^(bind-dynamic|bind-interfaces|interface=|no-dhcp-interface=|port=|dhcp-range=)' "$path"
        # Included file paths or custom hooks require review; contents withheld.
        awk '/^(conf-file|conf-dir|dhcp-script|enable-ra|enable-tftp)(=|$)/ { sub(/=.*/,"=<present, withheld>"); print }' "$path"
    fi
done
printf '\nKnown udhcpc PID / interface only\n'
if [ -r /var/run/udhcpc_lan.pid ]; then
    pid=$(cat /var/run/udhcpc_lan.pid)
    case $pid in ''|*[!0-9]*) printf 'Invalid PID\n';;
        *) if [ -r "/proc/$pid/cmdline" ]; then tr '\000' '\n' < "/proc/$pid/cmdline" | awk 'NR==1 {print "executable=" $0} prev=="-i" {print "interface=" $0} {prev=$0}'; fi;;
    esac
fi
printf '\nEND: no dbus/NVRAM export; no hooks, services, or network changed.\n'
