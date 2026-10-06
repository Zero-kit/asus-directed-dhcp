#!/bin/sh
# KoolShare API: params are argv[2..], never evaluated or exported.
set -f
umask 077
PATH=/koolshare/bin:/koolshare/scripts:$PATH
export PATH
BASE=${AXDHCP_HOME:-/koolshare/axdhcp}
request_id=${1:-}
action=${2:-}
case $request_id in ''|*[!0-9]*) exit 64;; esac
[ "${#request_id}" -le 12 ] || exit 64
which jq >/dev/null 2>&1 && which curl >/dev/null 2>&1 || exit 69
reply() {
    payload=$(jq -cn --arg ok "$1" --arg message "$2" --arg config "${config:-}" --arg status "${status:-}" --arg leases "${leases:-}" --arg logs "${logs:-}" --arg counters "${counters:-}" --argjson interfaces "${interfaces:-null}" '{ok:($ok=="1"),message:$message,config:$config,status:$status,leases:$leases,logs:$logs,counters:$counters,interfaces:$interfaces}') || exit 1
    # httpdb may embed _resp bodies in a quoted result without JSON escaping.
    # A base64 ASCII envelope avoids quotes, newlines and Unicode at that layer.
    encoded=$(printf '%s' "$payload" | jq -Rrs '@base64') || exit 1
    curl -fsS --max-time 10 --noproxy '*' -X POST --data-binary "AXDHCP64:$encoded" "http://127.0.0.1:3030/_resp/$request_id"
}
[ -f "$BASE/backend/axdhcp.sh" ] || { reply 0 'Backend missing'; exit 1; }
case $action in
    run)
        [ "$#" = 3 ] && [ "$3" = network-change-and-unverified-paths-acknowledged ] || { reply 0 '需要确认长期运行及尚未验收的风险'; exit 64; }
        result=$(sh "$BASE/backend/axdhcp.sh" run --network-change-confirmed --unverified-paths-acknowledged 2>&1) || { reply 0 "$result"; exit 1; }
        reply 1 "已启动长期运行；可随时停止。重启后是否启动取决于已保存的开机设置。$result";;
    stop)
        [ "$#" = 2 ] || { reply 0 'Invalid stop request'; exit 64; }
        result=$(sh "$BASE/backend/axdhcp.sh" stop 2>&1) || { reply 0 "$result"; exit 1; }
        reply 1 '已停止并撤销本插件规则';;
    check)
        [ "$#" = 2 ] || { reply 0 'Invalid check request'; exit 64; }
        logs=$(sh "$BASE/backend/check-env.sh" 2>&1 | head -c 48000)
        reply 1 '诊断信息已读取，本次检查未修改网络';;
    read)
        { [ "$#" = 2 ] || { [ "$#" = 3 ] && [ "$3" = status-only ]; }; } || { reply 0 'Invalid read request'; exit 64; }
        config=$(sh "$BASE/backend/axdhcp.sh" validate "$BASE/config/axdhcp.conf" 2>&1) || { reply 0 "$config"; exit 1; }
        status=$(sh "$BASE/backend/axdhcp.sh" status 2>&1)
        leases=$(sh "$BASE/backend/axdhcp.sh" leases 2>&1 | head -c 32768)
        logs=$(sh "$BASE/backend/axdhcp.sh" logs 2>&1 | head -c 32768)
        counters=$(sh "$BASE/backend/axdhcp.sh" counters 2>&1 | head -c 16384)
        if [ "$#" = 2 ]; then interfaces=$(sh "$BASE/backend/discover.sh" 2>/dev/null) || interfaces='[]'; fi
        reply 1 'Configuration and status read';;
    save)
        [ "$#" = 3 ] && [ "${#3}" -le 4096 ] || { reply 0 'Invalid save request'; exit 64; }
        # BusyBox firmware omits mktemp. Atomic mkdir refuses existing paths
        # and symlinks; never reuse an untrusted request directory.
        request_dir=/tmp/axdhcp-api.$$
        mkdir -m 700 "$request_dir" || { reply 0 'Cannot create private request directory'; exit 1; }
        incoming=$request_dir/config
        trap 'rm -f "$incoming"; rmdir "$request_dir"' 0
        trap 'exit 1' HUP INT TERM
        case $3 in
            AXDHCP64:*)
                encoded_config=${3#AXDHCP64:}
                case $encoded_config in ''|*[!A-Za-z0-9+/=]*) reply 0 'Invalid encoded configuration'; exit 64;; esac
                printf '%s' "$encoded_config" | jq -Rrse '@base64d' > "$incoming" || { reply 0 'Cannot decode configuration'; exit 64; };;
            *) reply 0 'Configuration encoding required; refresh the plugin page'; exit 64;;
        esac
        config=$(sh "$BASE/backend/axdhcp.sh" validate "$incoming" 2>&1) || { reply 0 "$config"; exit 1; }
        result=$(sh "$BASE/backend/axdhcp.sh" save "$incoming" 2>&1) || { reply 0 "$result"; exit 1; }
        reply 1 '已保存到路由器；保存不会启动 DHCP';;
    *) reply 0 'Action unavailable: read/save/check/run/stop only'; exit 64;;
esac
