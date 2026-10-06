#!/bin/sh
# DHCP lifecycle backend. Hardware packet-path validation remains pending.
set -f
umask 077
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
BASE=${AXDHCP_HOME:-$(cd "$(dirname "$SELF")/.." && pwd)}
RUN=${AXDHCP_RUN:-/tmp/axdhcp-runtime}
CONF=$BASE/config/axdhcp.conf
. "$BASE/backend/interfaces.sh"
LOCKED=0
EB=ebtables
REPORT_ERRORS=0
die() {
    if [ "$REPORT_ERRORS" = 1 ]; then
        if [ -n "${boot_owner:-}" ] && [ "$(cat "$RUN/boot.pending" 2>/dev/null)" = "$boot_owner" ]; then
            rm -f "$RUN/boot.pending"; state fault
        fi
        printf '%s\n' "$*" > "$RUN/last-error.$$" && mv "$RUN/last-error.$$" "$RUN/last-error"
        log "Operation failed: $*"
    fi
    printf '%s\n' "$*" >&2; exit 1
}
get() { awk -F= -v k="$1" '$1==k {print substr($0,index($0,"=")+1)}' "$2"; }
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$RUN/control.log"; }
state() { printf '%s\n' "$1" > "$RUN/state.new" && mv "$RUN/state.new" "$RUN/state"; }
identity() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
effective_uid() {
    if [ -r /proc/self/status ]; then
        awk '$1=="Uid:" { found=1; uid=$3 } END { if(!found) exit 1; print uid }' /proc/self/status
    else
        # Development hosts without procfs; target firmware uses procfs.
        id -u
    fi
}
ensure_run() {
    [ ! -L "$RUN" ] || die 'Runtime directory may not be a symlink'
    if [ ! -d "$RUN" ]; then mkdir -m 700 "$RUN" || die 'Cannot create runtime directory'; fi
    # BusyBox needs explicit -l; -n alone need not select long format.
    run_uid=$(ls -ldn "$RUN" | awk '{print $3}')
    current_uid=$(effective_uid) || die 'Cannot determine effective UID'
    [ "$run_uid" = "$current_uid" ] || die "Runtime directory owner mismatch: directory=$run_uid process=$current_uid path=$RUN"
    chmod 700 "$RUN" || die 'Cannot secure runtime directory'
}
unlock() { if [ "$LOCKED" = 1 ]; then rm -f "$RUN/lock/owner"; rmdir "$RUN/lock"; LOCKED=0; fi; }
lock() {
    lock_attempt=0
    while ! mkdir "$RUN/lock" 2>/dev/null; do
        lock_attempt=$((lock_attempt+1)); [ "$lock_attempt" -lt 5 ] || return 1; sleep 1
    done
    LOCKED=1
    printf '%s %s\n' "$$" "$(identity "$$")" > "$RUN/lock/owner"
    trap 'unlock' 0
    trap 'exit 1' HUP INT TERM
}
validate() { awk -v bridge_ip="${BRIDGE_IP:-}" -v bridge_prefix="${BRIDGE_PREFIX:-}" -f "$BASE/backend/validate.awk" "$1"; }
load() {
    [ -f "$CONF" ] || die 'Save a configuration first'
    validate "$CONF" > "$RUN/config.valid.$$" || { rm -f "$RUN/config.valid.$$"; die 'Configuration rejected'; }
    mv "$RUN/config.valid.$$" "$RUN/config.valid" || die 'Cannot publish validated configuration'
    BRIDGE=$(get bridge "$RUN/config.valid"); BACKHAUL=$(get backhaul "$RUN/config.valid")
    DOWN=$(get downstream "$RUN/config.valid"); TEST_SECONDS=$(get test_seconds "$RUN/config.valid")
}
same_generation() { [ "$(cat "$RUN/generation" 2>/dev/null)" = "$1" ]; }
owned_process() {
    role=$1
    [ -r "$RUN/$role.identity" ] || return 1
    read -r proc_pid proc_start proc_gen < "$RUN/$role.identity"
    [ -z "${2:-}" ] || [ "$proc_gen" = "$2" ] || return 1
    case $proc_pid:$proc_start in *[!0-9:]*|:|*:) return 1;; esac
    [ "$(identity "$proc_pid")" = "$proc_start" ] || return 1
    [ -r "/proc/$proc_pid/cmdline" ] || return 1
    if [ "$role" = dns ]; then
        [ "$(basename "$(readlink "/proc/$proc_pid/exe" 2>/dev/null)")" = dnsmasq ] || return 1
        tr '\000' '\n' < "/proc/$proc_pid/cmdline" | grep -Fx -- "--conf-file=$RUN/dnsmasq.conf" >/dev/null || return 1
    else
        tr '\000' '\n' < "/proc/$proc_pid/cmdline" | grep -Fx -- "$SELF" >/dev/null || return 1
        tr '\000' '\n' < "/proc/$proc_pid/cmdline" | grep -Fx -- "__$role" >/dev/null || return 1
    fi
    kill -0 "$proc_pid" 2>/dev/null
}
boot_wait_alive() {
    [ -s "$RUN/boot.pending" ] || return 1
    read -r waiting_pid waiting_start < "$RUN/boot.pending"
    case $waiting_pid:$waiting_start in *[!0-9:]*|:|*:) return 1;; esac
    [ "$(identity "$waiting_pid")" = "$waiting_start" ] && kill -0 "$waiting_pid" 2>/dev/null
}
stop_dns() {
    stop_token=${1:-}
    if [ ! -r "$RUN/dns.identity" ] && { [ -f "$RUN/dns.launching" ] || [ -f "$RUN/dnsmasq.pid" ]; }; then
        if [ -n "$stop_token" ] && [ -f "$RUN/dns.launching" ] && [ "$(cat "$RUN/dns.launching")" != "$stop_token" ]; then return 0; fi
        return 1
    fi
    if owned_process dns "$stop_token"; then
        kill -TERM "$proc_pid" || return 1
        n=0
        while owned_process dns "$stop_token" && [ "$n" -lt 5 ]; do sleep 1; n=$((n+1)); done
        if owned_process dns "$stop_token"; then kill -KILL "$proc_pid" || return 1; sleep 1; fi
        owned_process dns "$stop_token" && return 1
    elif [ -r "$RUN/dns.identity" ]; then
        read -r old_pid old_start old_gen < "$RUN/dns.identity"
        [ -z "$stop_token" ] || [ "$old_gen" = "$stop_token" ] || return 0
        # A live reused PID is not our process and must never be killed.
        if [ "$(identity "$old_pid")" = "$old_start" ]; then return 1; fi
    fi
    # Emergency supervisors stop only their generation; cleanup requires lock.
    if [ "$LOCKED" = 1 ]; then rm -f "$RUN/dns.identity" "$RUN/dnsmasq.pid" "$RUN/dns.launching"; fi
}
eb() { "$EB" -t filter "$@"; }
downstream_interfaces() {
    printf '%s\n' "$DOWN" | awk -F, 'NF<1 || NF>8 {exit 1} {for(i=1;i<=NF;i++) {if(length($i)>15 || $i!~/^[A-Za-z0-9_][A-Za-z0-9_.-]*$/ || seen[$i]++) exit 1; printf "%s%s",$i,(i==NF?"\n":" ")}}'
}
chain_exists() { eb -L "$1" >/dev/null 2>&1; }
jump() {
    case $1 in
        INPUT) eb "$2" INPUT ${3:+"$3"} -p IPv4 --ip-proto udp --ip-dport 67 --logical-in "$BRIDGE" -j AXDI;;
        OUTPUT) eb "$2" OUTPUT ${3:+"$3"} -p IPv4 --ip-proto udp --ip-sport 67 --logical-out "$BRIDGE" -j AXDO;;
        FORWARD) eb "$2" FORWARD ${3:+"$3"} --logical-in "$BRIDGE" -j AXDF;;
    esac
}
remove_rules() {
    # Only touch chains after this transaction created the ownership marker.
    [ -f "$RUN/rules.owned" ] || return 0
    BRIDGE=$(cat "$RUN/bridge.snapshot" 2>/dev/null || printf '%s' "${BRIDGE:-br0}")
    interface_name_valid "$BRIDGE" || return 1
    cleanup_ok=1
    for hook in INPUT OUTPUT FORWARD; do
        grep -Fx "jump:$hook" "$RUN/rules.owned" >/dev/null || continue
        jump "$hook" -D >/dev/null 2>&1 || :
    done
    for chain in AXDI AXDO AXDF; do
        grep -Fx "chain:$chain" "$RUN/rules.owned" >/dev/null || continue
        if chain_exists "$chain"; then
            eb -F "$chain" && eb -X "$chain" || cleanup_ok=0
        fi
    done
    [ "$cleanup_ok" = 1 ] || return 1
    rm -f "$RUN/rules.owned" "$RUN/rules.fingerprint"
}
rules_fingerprint() {
    for chain in AXDI AXDO AXDF; do eb -L "$chain" --Lx || return 1; done
    for spec in INPUT:AXDI OUTPUT:AXDO FORWARD:AXDF; do
        hook=${spec%:*}; chain=${spec#*:}
        listing=$(eb -L "$hook" --Lx) || return 1
        printf '%s\n' "$listing" | awk -v h="$hook" -v c="$chain" '
            $0 ~ " -A " h " " { n++; if(n==1 && $NF==c && $(NF-1)=="-j") first=1; if($NF==c && $(NF-1)=="-j") own++ }
            END { if(first!=1 || own!=1) exit 1 }' || return 1
        printf '%s\n' "$listing" | awk -v c="$chain" '$NF==c && $(NF-1)=="-j"'
    done
}
install_rules() {
    downstream_interfaces >/dev/null || return 1
    for chain in AXDI AXDO AXDF; do chain_exists "$chain" && return 1; done
    : > "$RUN/rules.owned" || return 1
    for chain in AXDI AXDO AXDF; do
        eb -N "$chain" || return 1
        printf 'chain:%s\n' "$chain" >> "$RUN/rules.owned" || return 1
    done
    for iface in $(downstream_interfaces); do
        eb -A AXDI -i "$iface" -j RETURN || return 1
        eb -A AXDO -o "$iface" -j RETURN || return 1
        eb -A AXDF -p IPv4 --ip-proto udp --ip-dport 67 -i "$iface" -j DROP || return 1
        eb -A AXDF -p IPv4 --ip-proto udp --ip-sport 67 -o "$iface" -j DROP || return 1
        eb -A AXDF -p IPv4 --ip-proto udp --ip-sport 67 -i "$iface" -j DROP || return 1
    done
    eb -A AXDI -j DROP || return 1
    eb -A AXDO -j DROP || return 1
    eb -A AXDF -j RETURN || return 1
    for hook in INPUT OUTPUT FORWARD; do
        jump "$hook" -I 1 || return 1
        printf 'jump:%s\n' "$hook" >> "$RUN/rules.owned" || return 1
    done
    rules_fingerprint > "$RUN/rules.fingerprint" || return 1
}
check_rules() {
    observed=$(rules_fingerprint) || return 1
    [ "$observed" = "$(cat "$RUN/rules.fingerprint" 2>/dev/null)" ]
}
network_fingerprint() {
    downstream_interfaces >/dev/null || return 1
    [ -d "$NET_ROOT/$BRIDGE/bridge" ] || return 1
    [ "$BRIDGE" != "$BACKHAUL" ] || return 1
    if wireless_prefix "$BACKHAUL" >/dev/null; then [ "$(wireless_role "$BACKHAUL")" = uplink ] || return 1
    else [ "$(cat "$NET_ROOT/$BACKHAUL/type")" = 1 ] || return 1; fi
    for iface in $(downstream_interfaces); do
        [ "$iface" != "$BACKHAUL" ] && [ "$iface" != "$BRIDGE" ] || return 1
        [ "$(wireless_role "$iface")" = ap ] || return 1
    done
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 0 ] || return 1
    for iface in "$BACKHAUL" $(downstream_interfaces); do
        interface_is_member "$BRIDGE" "$iface" || return 1
        ip link show dev "$iface" | grep 'UP' >/dev/null || return 1
        printf '%s operstate=' "$iface"
        cat "$NET_ROOT/$iface/operstate" || return 1
        if [ -r "$NET_ROOT/$iface/carrier" ]; then
            carrier=$(cat "$NET_ROOT/$iface/carrier") || return 1
            [ "$carrier" = 1 ] || return 1
            printf '%s carrier=%s\n' "$iface" "$carrier"
        fi
    done
    for key in productid sw_mode re_mode wlc_mode wlc_band lan_ifname lan_ifnames wl0_ifname wl1_ifname wl1_vifs; do
        printf '%s=%s\n' "$key" "$(nvram get "$key")"
    done
    ip -4 addr show dev "$BRIDGE" || return 1
    ip -4 route show default || return 1
    for iface in "$BRIDGE" "$BACKHAUL" $(downstream_interfaces); do
        printf '%s=' "$iface"; cat "$NET_ROOT/$iface/address" || return 1
    done
    for iface in "$BACKHAUL" $(downstream_interfaces); do
        wifi_prefix=$(wireless_prefix "$iface") || continue
        printf '%s role=%s prefix=%s\n' "$iface" "$(wireless_role "$iface" "$wifi_prefix")" "$wifi_prefix"
        bssid=$(wl -i "$iface" bssid 2>/dev/null) || return 1
        printf '%s\n' "$bssid" | grep -E '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$' >/dev/null || return 1
        [ "$bssid" != 00:00:00:00:00:00 ] || return 1
        printf '%s %s\n' "$iface" "$bssid"
    done
}
check_system_config() {
    [ -r /etc/dnsmasq.conf ] || die 'System dnsmasq configuration unavailable'
    awk -F= -v bridge="$BRIDGE" '$1 ~ /^[ \t]*no-dhcp-interface$/ {gsub(/[ \t]/,"",$2); if($2==bridge || $2=="*") found=1} END {exit !found}' /etc/dnsmasq.conf || die 'System DHCP exclusion unconfirmed for selected bridge'
    if grep -E '^[[:space:]]*(dhcp-range|conf-file)(=|[[:space:]])|^[[:space:]]*(enable-ra|enable-tftp)(=|[[:space:]]|$)' /etc/dnsmasq.conf >/dev/null; then die 'System service configuration needs review'; fi
    includes=$(awk '/^[ \t]*conf-dir=/ {sub(/^[ \t]*conf-dir=/, ""); print}' /etc/dnsmasq.conf)
    if [ -n "$includes" ]; then
        [ "$includes" = /jffs/configs/dnsmasq.d ] || die 'Unreviewed dnsmasq include directory'
        [ -d "$includes" ] && [ ! -L "$includes" ] || die 'Include directory unavailable or symlink'
        [ -z "$(ls -A "$includes")" ] || die 'Include directory must remain empty for this test'
    fi
}
check_default_route() {
    expected_gateway=$(get gateway "$RUN/config.valid")
    default_routes=$(ip -4 route show default 2>&1) || die "Cannot read default route: $default_routes"
    printf '%s\n' "$default_routes" | awk -v gateway="$expected_gateway" -v bridge="$BRIDGE" '
        $1=="default" || $1=="0.0.0.0/0" {
            count++; via=""; dev=""; invalid=0
            for(i=2;i<=NF;i++) {
                if($i=="via") via=$(i+1)
                if($i=="dev") dev=$(i+1)
                if($i=="nexthop" || $i=="linkdown") invalid=1
            }
            if(via==gateway && dev==bridge && !invalid) matched++
        }
        END {exit !(count==1 && matched==1)}' || die "Default route mismatch: expected gateway=$expected_gateway interface=$BRIDGE; actual=$default_routes"
}
preflight() {
    [ "$(effective_uid)" = 0 ] || die 'Network operations require root'
    for required in ip wl nvram ebtables dnsmasq readlink nohup; do which "$required" >/dev/null 2>&1 || die "Required network tool missing: $required"; done
    network_fingerprint > "$RUN/network.initial" || die "Interface identity or network environment rejected: bridge=$BRIDGE backhaul=$BACKHAUL downstream=$DOWN; check membership, wireless roles and link state"
    BRIDGE_CIDR=$(ip -4 addr show dev "$BRIDGE" | awk '$1=="inet" {print $2}')
    case $BRIDGE_CIDR in *" "*|*"
"*|'') die 'Expected one IPv4 bridge address';; esac
    BRIDGE_IP=${BRIDGE_CIDR%/*}; BRIDGE_PREFIX=${BRIDGE_CIDR#*/}
    validate "$CONF" > "$RUN/config.valid" || die 'Pool does not match live bridge'
    check_default_route
    check_system_config
    dnsmasq --version | grep 'DHCP' >/dev/null || die 'DHCP capability unavailable'
}
local_mac_exclusions() {
    local_interfaces=$(ls -1 /sys/class/net) || die 'DHCP configuration generation failed: cannot enumerate local interfaces'
    for iface in $local_interfaces; do
        link_type=$(cat "/sys/class/net/$iface/type") || die "DHCP configuration generation failed: cannot read interface type: $iface"
        # ARPHRD_ETHER=1. Tunnel/loopback link addresses are not Ethernet
        # client MACs (some tunnels expose 20-byte addresses).
        [ "$link_type" = 1 ] || continue
        mac=$(cat "/sys/class/net/$iface/address") || die "DHCP configuration generation failed: cannot read Ethernet address: $iface"
        case $mac in 00:00:00:00:00:00|'')
            case " $BRIDGE $BACKHAUL $(downstream_interfaces) " in *" $iface "*) die "DHCP configuration generation failed: missing Ethernet address: $iface";; *) continue;; esac;;
        esac
        printf '%s\n' "$mac" | grep -E '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$' >/dev/null || die "DHCP configuration generation failed: invalid Ethernet address: interface=$iface type=$link_type address=$mac"
        printf 'dhcp-host=%s,ignore\n' "$mac" || die 'DHCP configuration generation failed: cannot write local MAC exclusions'
    done
}
make_dns_config() {
    # Prepare exclusions separately so every failure has an exact diagnostic,
    # and a failed enumeration cannot silently leave an incomplete config.
    local_mac_exclusions > "$RUN/mac-exclusions" || die 'DHCP configuration generation failed: cannot prepare MAC exclusions'
    {
        # Empty user/group explicitly retain the preflight-verified UID 0
        # identity. Firmware may call that account admin rather than root.
        printf 'port=0\nuser=\ngroup=\nno-resolv\nno-hosts\ndhcp-ignore-clid\nbind-interfaces\ninterface=%s\n' "$BRIDGE"
        printf 'pid-file=%s/dnsmasq.pid\ndhcp-leasefile=%s/leases\nlog-facility=%s/dhcp.log\nlog-dhcp\n' "$RUN" "$RUN" "$RUN"
        printf 'dhcp-range=%s,%s,%s,%ss\n' "$(get pool_start "$RUN/config.valid")" "$(get pool_end "$RUN/config.valid")" "$(get netmask "$RUN/config.valid")" "$(get lease_seconds "$RUN/config.valid")"
        printf 'dhcp-option=option:router,%s\ndhcp-option=option:dns-server,%s\n' "$(get gateway "$RUN/config.valid")" "$(get dns "$RUN/config.valid")"
        # Option 54 is generated internally by dnsmasq from the serving
        # interface. It must not be supplied as a configurable dhcp-option.
        cat "$RUN/mac-exclusions"
    } > "$RUN/dnsmasq.conf" || die 'DHCP configuration generation failed: cannot write dnsmasq configuration'
    dns_check=$(dnsmasq --test "--conf-file=$RUN/dnsmasq.conf" 2>&1) || {
        printf '%s\n' "$dns_check" > "$RUN/dnsmasq-check.log"
        [ -n "$dns_check" ] || dns_check='dnsmasq --test exited with failure but no diagnostic output'
        die "Isolated dnsmasq configuration check failed: $dns_check"
    }
    rm -f "$RUN/dnsmasq-check.log" || die 'DHCP configuration generation failed: cannot clear previous dnsmasq check log'
}
abort_transaction() {
    stop_dns || { state fault; log 'DHCP identity/termination uncertain; filters retained'; return 1; }
    remove_rules || { state fault; log 'Rule cleanup incomplete'; return 1; }
    rm -f "$RUN/generation" "$RUN/ready"
    state "$1"
}
dns_startup_details() {
    printf 'pid=%s recorded_start=%s current_start=%s\n' "$dns_pid" "$dns_start" "$(identity "$dns_pid")"
    if kill -0 "$dns_pid" 2>/dev/null; then
        printf 'process=alive executable=%s\n' "$(readlink "/proc/$dns_pid/exe" 2>/dev/null)"
        if [ -r "/proc/$dns_pid/cmdline" ]; then
            printf 'arguments='; tr '\000' ' ' < "/proc/$dns_pid/cmdline"; printf '\n'
        fi
    else printf 'process=exited\n'; fi
    for diagnostic in "$RUN/dnsmasq-startup.log" "$RUN/dhcp.log"; do
        if [ -s "$diagnostic" ]; then printf '%s:\n' "$diagnostic"; tail -n 15 "$diagnostic"; fi
    done
}
launch() {
    mode=$1; shift
    lifetime=${LIFETIME:-temporary}
    if [ "$mode" = filters ]; then
        [ "$#" = 1 ] && [ "$1" = --network-change-confirmed ] || die 'Requires explicit network authorization'
    elif [ "$lifetime" = continuous ]; then
        [ "$#" = 2 ] && [ "$1" = --network-change-confirmed ] && [ "$2" = --unverified-paths-acknowledged ] || die 'Requires network authorization and acknowledgement of pending hardware validation'
    else
        [ "$#" = 2 ] && [ "$1" = --network-change-confirmed ] && [ "$2" = --filter-paths-confirmed ] || die 'Requires explicit network authorization and hardware filtering-path confirmation'
    fi
    load
    if [ "$mode" = dhcp ]; then
        [ "$(get enabled "$RUN/config.valid")" = 1 ] || die 'Configuration is disabled'
        [ "$(get pool_confirmed "$RUN/config.valid")" = 1 ] && [ "$(get dns_confirmed "$RUN/config.valid")" = 1 ] || die 'Confirm pool ownership and DNS service first'
    fi
    if [ -s "$RUN/generation" ]; then
        [ "$(cat "$RUN/mode")" = "$mode" ] && [ "$(cat "$RUN/lifetime" 2>/dev/null || printf temporary)" = "$lifetime" ] && check_rules && { [ "$mode" = filters ] || owned_process dns; } || die 'Existing transaction needs stop/recovery'
        printf 'Existing transaction; lifetime unchanged\n'; return
    fi
    preflight
    [ ! -f "$RUN/dns.identity" ] && [ ! -f "$RUN/dns.launching" ] && [ ! -f "$RUN/dnsmasq.pid" ] && [ ! -f "$RUN/rules.owned" ] || die 'Residual transaction requires recovery'
    if [ "$mode" = dhcp ]; then make_dns_config || die 'Isolated dnsmasq configuration check failed'; fi
    token="$(date +%s)-$$"
    printf '%s\n' "$token" > "$RUN/generation"
    printf '%s\n' "$mode" > "$RUN/mode"
    printf '%s\n' "$lifetime" > "$RUN/lifetime"
    printf '%s\n' "$DOWN" > "$RUN/downstream.snapshot" || { abort_transaction fault; die 'Cannot record selected interfaces'; }
    printf '%s\n' "$BRIDGE" > "$RUN/bridge.snapshot" || { abort_transaction fault; die 'Cannot record selected bridge'; }
    printf '%s\n' "$BACKHAUL" > "$RUN/backhaul.snapshot" || { abort_transaction fault; die 'Cannot record selected backhaul'; }
    # /proc/uptime is monotonic: wall-clock/NTP changes cannot extend the test.
    now=$(awk '{print int($1)}' /proc/uptime)
    if [ "$lifetime" = continuous ]; then
        printf 'continuous\n' > "$RUN/deadline"; state running
    else
        printf '%s\n' "$((now+TEST_SECONDS))" > "$RUN/deadline"; state testing
    fi
    nohup "$SELF" __timer "$token" </dev/null >> "$RUN/control.log" 2>&1 &
    timer_pid=$!; printf '%s %s\n' "$timer_pid" "$(identity "$timer_pid")" > "$RUN/timer.identity"
    sleep 1
    owned_process timer || { abort_transaction fault; die 'Detached rollback timer failed'; }
    if ! install_rules; then abort_transaction fault; die 'Filter deployment failed; DHCP was not started'; fi
    if [ "$mode" = dhcp ]; then
        printf '%s\n' "$token" > "$RUN/dns.launching" || { abort_transaction fault; die 'Cannot record DHCP launch intent'; }
        : > "$RUN/dnsmasq-startup.log" || { abort_transaction fault; die 'Cannot create DHCP startup diagnostic log'; }
        dnsmasq --keep-in-foreground "--conf-file=$RUN/dnsmasq.conf" </dev/null >> "$RUN/dnsmasq-startup.log" 2>&1 &
        dns_pid=$!; dns_start=$(identity "$dns_pid")
        printf '%s %s %s\n' "$dns_pid" "$dns_start" "$token" > "$RUN/dns.identity"
        sleep 1
        if ! owned_process dns; then
            startup_reason=$(dns_startup_details)
            if ! kill -0 "$dns_pid" 2>/dev/null; then
                wait "$dns_pid"; startup_exit=$?
                startup_reason="$startup_reason
exit_code=$startup_exit"
            fi
            abort_transaction fault || :
            die "DHCP startup failed: $startup_reason"
        fi
    fi
    nohup "$SELF" __watch "$token" </dev/null >> "$RUN/control.log" 2>&1 &
    watch_pid=$!; printf '%s %s\n' "$watch_pid" "$(identity "$watch_pid")" > "$RUN/watch.identity"
    sleep 1
    owned_process watch && owned_process timer && check_rules || { abort_transaction fault; die 'Supervision failed'; }
    printf '%s\n' "$token" > "$RUN/ready"
    rm -f "$RUN/last-error" "$RUN/boot.last-error"
    log "Transaction started ($lifetime); hardware acceptance remains unverified"
    printf 'service=%s\ngeneration=%s\nlifetime=%s\n' "$mode" "$token" "$lifetime"
}
supervision_fault() {
    # Stop DHCP before waiting for a possibly stuck control lock.
    stop_dns "$token" || :
    log "$1"
    if lock; then same_generation "$token" && abort_transaction fault; unlock; else : > "$RUN/fault.$token"; fi
}
watch() {
    token=$1
    while same_generation "$token"; do
        if [ -f "$RUN/ready" ]; then
            live=$(network_fingerprint) || live=invalid
            if ! check_rules || [ "$live" != "$(cat "$RUN/network.initial")" ] || ! owned_process timer || { [ "$(cat "$RUN/mode")" = dhcp ] && ! owned_process dns; }; then
                supervision_fault 'Watchdog detected rule, process or interface fault'
                exit 1
            fi
        fi
        sleep 2
    done
    stop_dns "$token" || :
}
timer() {
    token=$1
    while same_generation "$token"; do
        if [ -f "$RUN/ready" ] && ! owned_process watch; then
            supervision_fault 'Rollback supervisor detected watchdog exit'
            exit 1
        fi
        now=$(awk '{print int($1)}' /proc/uptime)
        deadline=$(cat "$RUN/deadline" 2>/dev/null)
        if [ "$deadline" = continuous ]; then
            [ "$(cat "$RUN/lifetime" 2>/dev/null)" = continuous ] || { stop_dns "$token"; : > "$RUN/fault.$token"; exit 1; }
            sleep 1
            continue
        fi
        case $deadline in ''|*[!0-9]*) stop_dns "$token"; : > "$RUN/fault.$token"; exit 1;; esac
        if [ "$now" -ge "$deadline" ]; then
            if lock; then
                if same_generation "$token"; then abort_transaction unverified; log 'Deadline reached; rolled back'; fi
                unlock
            else
                stop_dns "$token" || :
                : > "$RUN/fault.$token"; log 'DHCP stopped at deadline; cleanup blocked by lock'
            fi
            exit
        fi
        sleep 1
    done
    stop_dns "$token" || :
}
boot() {
    ensure_run; REPORT_ERRORS=1
    log 'Boot startup invoked'
    lock || die 'Busy/stale lock; consult recovery manual'
    load
    [ "$(get autostart "$RUN/config.valid")" = 1 ] && [ "$(get enabled "$RUN/config.valid")" = 1 ] || { log 'Boot startup skipped: saved autostart or enabled is off'; unlock; return 0; }
    [ ! -s "$RUN/generation" ] || { log 'Boot startup skipped: transaction already exists'; unlock; return 0; }
    if [ -s "$RUN/boot.pending" ]; then
        read -r boot_pid boot_start < "$RUN/boot.pending"
        case $boot_pid:$boot_start in *[!0-9:]*|:|*:) :;;
            *) [ "$(identity "$boot_pid")" != "$boot_start" ] || { unlock; return 0; };;
        esac
    fi
    boot_owner="$$ $(identity "$$")"
    printf '%s\n' "$boot_owner" > "$RUN/boot.pending" || die 'Cannot record boot startup'
    state starting; log 'Boot startup waiting for network readiness'
    boot_attempt=0
    while [ "$boot_attempt" -lt 90 ]; do
        [ "$(cat "$RUN/boot.pending" 2>/dev/null)" = "$boot_owner" ] || { unlock; return 0; }
        # Readiness probing is read-only and holds the same lock as manual
        # start/stop/save. The subprocess contains preflight's exit-on-error.
        if ( REPORT_ERRORS=0; preflight ) > "$RUN/boot.last-error" 2>&1; then
            rm -f "$RUN/boot.pending"
            LIFETIME=continuous
            launch dhcp --network-change-confirmed --unverified-paths-acknowledged
            unlock; return 0
        fi
        unlock
        sleep 2
        lock || die 'Busy/stale lock during boot startup'
        boot_attempt=$((boot_attempt+1))
    done
    [ "$(cat "$RUN/boot.pending" 2>/dev/null)" = "$boot_owner" ] || { unlock; return 0; }
    rm -f "$RUN/boot.pending"
    state fault
    boot_reason=$(cat "$RUN/boot.last-error" 2>/dev/null)
    die "Boot startup timed out: $boot_reason"
}
status() {
    s=$(cat "$RUN/state" 2>/dev/null); [ -n "$s" ] || s=unverified
    status_token=$(cat "$RUN/generation" 2>/dev/null)
    [ ! -f "$RUN/fault.$status_token" ] || s=fault
    boot_dead=0
    if [ -s "$RUN/boot.pending" ] && ! boot_wait_alive; then s=fault; boot_dead=1; fi
    printf 'state=%s\nhardware_verified=0\n' "$s"
    if [ -r "$BASE/VERSION" ]; then printf 'backend_version='; cat "$BASE/VERSION"; fi
    if [ -s "$RUN/last-error" ]; then printf 'last_error='; tr '\n' ' ' < "$RUN/last-error"; printf '\n'; fi
    if [ "$boot_dead" = 1 ]; then printf 'last_error=Boot startup worker exited; stop and retry\n'
    elif [ -s "$RUN/boot.pending" ]; then printf 'boot_pending=1\n'; fi
    if owned_process dns; then printf 'service=started\n'; else printf 'service=stopped\n'; fi
    if [ -s "$RUN/generation" ]; then
        printf 'lifetime=%s\n' "$(cat "$RUN/lifetime" 2>/dev/null || printf temporary)"
        printf 'generation=%s\nmode=%s\n' "$(cat "$RUN/generation")" "$(cat "$RUN/mode")"
        if check_rules; then printf 'rules=intact\n'; else printf 'rules=fault\n'; fi
        now=$(awk '{print int($1)}' /proc/uptime); deadline=$(cat "$RUN/deadline")
        if [ "$deadline" != continuous ]; then printf 'remaining_seconds=%s\n' "$((deadline-now))"; fi
    fi
}
case ${1:-help} in
    help) printf 'axdhcp: validate FILE | save FILE | status | counters | leases | logs\n  run --network-change-confirmed --unverified-paths-acknowledged\n  test/start --network-change-confirmed --filter-paths-confirmed\n  filters-test --network-change-confirmed\n  boot (saved autostart only) | stop | rollback GENERATION\nrun is continuous; test/start and filters-test expire. Hardware validation remains pending.\n';;
    validate) [ "$#" = 2 ] || die 'validate FILE'; validate "$2";;
    save)
        [ "$#" = 2 ] || die 'save FILE'; ensure_run; REPORT_ERRORS=1; lock || die 'Busy/stale lock; consult recovery manual'
        [ ! -s "$RUN/generation" ] || die 'Stop the active transaction before saving'
        mkdir -p "$BASE/config" || die 'Cannot create config directory'
        validate "$2" > "$BASE/config/axdhcp.conf.new" || { rm -f "$BASE/config/axdhcp.conf.new"; die 'Configuration rejected'; }
        mv "$BASE/config/axdhcp.conf.new" "$CONF" || die 'Cannot save configuration'
        if [ -f "$RUN/boot.pending" ]; then rm -f "$RUN/boot.pending"; state unverified; fi
        rm -f "$RUN/last-error"
        printf 'Saved; no network changes\n';;
    boot) [ "$#" = 1 ] || die 'boot takes no arguments'; boot;;
    run|start|test|filters-test)
        action=$1; shift; ensure_run; REPORT_ERRORS=1; lock || die 'Busy/stale lock; consult recovery manual'
        rm -f "$RUN/boot.pending"
        LIFETIME=temporary
        if [ "$action" = run ]; then LIFETIME=continuous; fi
        if [ "$action" = filters-test ]; then launch filters "$@"; else launch dhcp "$@"; fi;;
    stop)
        ensure_run; REPORT_ERRORS=1; lock || die 'Busy/stale lock; consult recovery manual'
        rm -f "$RUN/boot.pending"
        abort_transaction unverified || die 'Recovery required; see retained filters'
        log 'Stopped and restored plugin-owned rules';;
    rollback)
        [ "$#" = 2 ] || die 'rollback GENERATION'; ensure_run; lock || die 'Busy/stale lock'
        if same_generation "$2"; then abort_transaction unverified || die 'Rollback incomplete'; fi;;
    status) if [ -d "$RUN" ]; then status; else printf 'state=unverified\nservice=stopped\nhardware_verified=0\n'; fi;;
    counters) for chain in AXDI AXDO AXDF; do eb -L "$chain" --Lc || exit 1; done;;
    leases) [ ! -f "$RUN/leases" ] || cat "$RUN/leases";;
    logs) for path in "$RUN/control.log" "$RUN/dhcp.log" "$RUN/dnsmasq-check.log" "$RUN/dnsmasq-startup.log"; do [ ! -f "$path" ] || tail -n 100 "$path"; done;;
    __timer|__watch)
        internal=$1; [ "$#" = 2 ] || exit 1; [ -d "$RUN" ] || exit 1
        # Recovery must not depend on mutable user configuration or its parser.
        BRIDGE=$(cat "$RUN/bridge.snapshot" 2>/dev/null || printf br0)
        BACKHAUL=$(cat "$RUN/backhaul.snapshot" 2>/dev/null || printf eth7)
        interface_name_valid "$BRIDGE" && interface_name_valid "$BACKHAUL" || { stop_dns "$2"; exit 1; }
        DOWN=$(cat "$RUN/downstream.snapshot" 2>/dev/null)
        downstream_interfaces >/dev/null || { stop_dns "$2"; exit 1; }
        if [ "$internal" = __timer ]; then timer "$2"; else watch "$2"; fi;;
    *) die 'Unknown action';;
esac
