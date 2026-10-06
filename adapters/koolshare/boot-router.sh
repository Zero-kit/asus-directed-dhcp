#!/bin/sh
set -f
PATH=/koolshare/bin:/koolshare/scripts:$PATH
export PATH
BASE=/koolshare/axdhcp
# services-start dispatches V*.sh without arguments, including AP/repeater mode.
case ${1:-start} in
    start)
        # The backend checks saved opt-in and serializes boot/manual actions.
        # Network readiness may take time; never block firmware initialization.
        [ -f "$BASE/backend/axdhcp.sh" ] || exit 1
        nohup sh "$BASE/backend/axdhcp.sh" boot </dev/null >/dev/null 2>&1 &
        ;;
    stop) sh "$BASE/backend/axdhcp.sh" stop;;
    *) exit 64;;
esac
