#!/bin/sh
set -f
BASE=$(cd "$(dirname "$0")" && pwd)
. "$BASE/interfaces.sh"
# Globs are used only for reading sysfs, never deleting or executing entries.
set +f
interface_inventory | jq -s '.'
