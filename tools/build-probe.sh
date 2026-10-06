#!/bin/sh
# Build the one-shot package for the documented rogsoft hnd upload contract.
set -eu
set -f
BASE=$(cd "$(dirname "$0")/.." && pwd)
OUT=$BASE/dist
mkdir -p "$OUT"
stage=$(mktemp -d "${TMPDIR:-/tmp}/axdhcp-probe-build.XXXXXX")
cleanup() {
    rm -f "$stage/axdhcp_probe/install.sh" "$stage/axdhcp_probe/uninstall.sh" "$stage/axdhcp_probe/scripts/axdhcp_probe_collect.sh" "$stage/axdhcp_probe/webs/Module_axdhcp_probe.asp" "$stage/axdhcp_probe/.valid" "$stage/axdhcp_probe/version"
    rmdir "$stage/axdhcp_probe/scripts" "$stage/axdhcp_probe/webs" "$stage/axdhcp_probe" "$stage"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
mkdir -p "$stage/axdhcp_probe/scripts" "$stage/axdhcp_probe/webs"
cp "$BASE/adapters/koolshare/probe-install.sh" "$stage/axdhcp_probe/install.sh"
cp "$BASE/tools/collect-env.sh" "$stage/axdhcp_probe/scripts/axdhcp_probe_collect.sh"
cp "$BASE/adapters/koolshare/Module_axdhcp_probe.asp" "$stage/axdhcp_probe/webs/Module_axdhcp_probe.asp"
cp "$BASE/adapters/koolshare/probe-uninstall.sh" "$stage/axdhcp_probe/uninstall.sh"
cp "$BASE/adapters/koolshare/probe.valid" "$stage/axdhcp_probe/.valid"
version=0.1.3
printf '%s\n' "$version" > "$stage/axdhcp_probe/version"
chmod 755 "$stage/axdhcp_probe/install.sh" "$stage/axdhcp_probe/uninstall.sh" "$stage/axdhcp_probe/scripts/axdhcp_probe_collect.sh"
COPYFILE_DISABLE=1 tar -czf "$OUT/axdhcp_probe-$version.tar.gz" -C "$stage" axdhcp_probe
if which sha256sum >/dev/null 2>&1; then
    sha256sum "$OUT/axdhcp_probe-$version.tar.gz"
else shasum -a 256 "$OUT/axdhcp_probe-$version.tar.gz"; fi
printf 'One-shot diagnostic upload package; target software-center acceptance remains untested. No DHCP service included.\n'
