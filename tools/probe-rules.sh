#!/bin/sh
# Explicitly requested detached capability probe, NOT the read-only collector.
set -f
[ "${1:-}" = --detached-chain-confirmed ] || { printf 'Usage: sh probe-rules.sh --detached-chain-confirmed\n' >&2; exit 1; }
chain=AXDP
ebtables -t filter -L "$chain" >/dev/null 2>&1 && { printf 'AXDP exists; refusing to touch it\n' >&2; exit 1; }
ebtables -t filter -N "$chain" || exit 1
cleanup() { ebtables -t filter -F "$chain"; ebtables -t filter -X "$chain"; }
trap cleanup 0
trap 'exit 1' HUP INT TERM
for iface in eth6 wl1.1; do
    ebtables -t filter -A "$chain" -p IPv4 --ip-proto udp --ip-dport 67 --logical-in br0 -i "$iface" -j DROP || exit 1
    ebtables -t filter -A "$chain" -p IPv4 --ip-proto udp --ip-sport 67 --logical-out br0 -o "$iface" -j DROP || exit 1
done
ebtables -t filter -L "$chain" --Lx || exit 1
ebtables -t filter -L "$chain" --Lc || exit 1
printf 'Detached syntax capability only; packet paths remain UNVERIFIED\n'
