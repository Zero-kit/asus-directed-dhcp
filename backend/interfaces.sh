#!/bin/sh
# Read-only interface discovery; never creates bridges or wireless interfaces.
NET_ROOT=${AXDHCP_NET_ROOT:-/sys/class/net}
interface_name_valid() {
    case $1 in ''|-*|*[!A-Za-z0-9_.-]*) return 1;; esac
    [ "${#1}" -le 15 ]
}
wireless_prefix() {
    for radio in 0 1 2 3 4 5 6 7; do
        primary=$(nvram get "wl${radio}_ifname")
        if [ "$primary" = "$1" ]; then printf 'wl%s\n' "$radio"; return 0; fi
        for vif in $(nvram get "wl${radio}_vifs"); do
            interface_name_valid "$vif" || continue
            prefix=$vif
            if [ "$vif" = "$1" ] || [ "$(nvram get "${vif}_ifname")" = "$1" ]; then
                case $prefix in wl[0-7].[0-9]*) printf '%s\n' "$prefix"; return 0;; esac
            fi
        done
    done
    return 1
}
wireless_role() {
    detected_prefix=${2:-}
    if [ -z "$detected_prefix" ]; then detected_prefix=$(wireless_prefix "$1") || return 1; fi
    case $detected_prefix in
        *.*) :;;
        *)
            detected_unit=${detected_prefix#wl}
            if [ "$(nvram get sw_mode)" = 3 ] && [ "$(nvram get wlc_mode)" = 1 ] && [ "$(nvram get wlc_band)" = "$detected_unit" ]; then
                printf 'uplink\n'; return 0
            fi;;
    esac
    detected_mode=$(nvram get "${detected_prefix}_mode")
    case $detected_mode in
        ap) printf 'ap\n';;
        sta|wet|psta|psr) printf 'uplink\n';;
        '')
            driver_status=$(wl -i "$1" status 2>/dev/null)
            if printf '%s\n' "$driver_status" | grep -E 'Mode:[[:space:]]*AP([[:space:]]|$)' >/dev/null; then printf 'ap\n'; return 0; fi
            if printf '%s\n' "$driver_status" | grep -E 'Mode:[[:space:]]*(Managed|STA|WET)([[:space:]]|$)' >/dev/null; then printf 'uplink\n'; return 0; fi
            printf 'unknown\n';;
        *) printf 'unknown\n';;
    esac
}
interface_is_member() {
    interface_name_valid "$1" && interface_name_valid "$2" && [ -d "$NET_ROOT/$1/bridge" ] && [ -d "$NET_ROOT/$1/brif/$2" ]
}
interface_inventory() {
    for path in "$NET_ROOT"/*; do
        [ -e "$path" ] || continue
        iface=${path##*/}
        interface_name_valid "$iface" || continue
        kind=ethernet; role=unknown; ssid=; band=; prefix=; mode=; member_of=
        if [ -d "$path/bridge" ]; then kind=bridge; role=bridge
        elif prefix=$(wireless_prefix "$iface"); then
            kind=wifi; role=$(wireless_role "$iface" "$prefix"); mode=$(nvram get "${prefix}_mode")
            ssid=$(nvram get "${prefix}_ssid")
            radio=${prefix#wl}; radio=${radio%%.*}
            if [ "$role" = uplink ]; then
                upstream_ssid=$(nvram get "wlc${radio}_ssid")
                if [ -z "$upstream_ssid" ] && [ "$(nvram get wlc_band)" = "$radio" ]; then upstream_ssid=$(nvram get wlc_ssid); fi
                [ -z "$upstream_ssid" ] || ssid=$upstream_ssid
            fi
            case $(nvram get "wl${radio}_nband") in 1) band='5 GHz';; 2) band='2.4 GHz';; 4) band='6 GHz';; *) band='频段未确定';; esac
        elif [ "$(cat "$path/type" 2>/dev/null)" != 1 ]; then continue
        fi
        for bridge_path in "$NET_ROOT"/*; do
            [ -d "$bridge_path/bridge" ] || continue
            [ ! -d "$bridge_path/brif/$iface" ] || member_of=${bridge_path##*/}
        done
        jq -cn --arg name "$iface" --arg kind "$kind" --arg role "$role" --arg ssid "$ssid" --arg band "$band" --arg prefix "$prefix" --arg mode "$mode" --arg bridge "$member_of" '{name:$name,kind:$kind,role:$role,ssid:$ssid,band:$band,prefix:$prefix,mode:$mode,bridge:$bridge}' || return 1
    done
}
