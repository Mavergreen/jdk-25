#!/bin/sh
# platform: host-agnostic
#   usage: version.sh auto|local
#          shipyard's scripts/version.sh, reading UPSTREAM_VERSION, which build/derive-upstream-version.sh
#          writes from components/jdk/version's REF first.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$SELF/.." && pwd)"; export MAVERICKS_ROOT
sh "$SELF/derive-upstream-version.sh" > /dev/null
MAVERICKS_UPSTREAM_FILE="$MAVERICKS_ROOT/UPSTREAM_VERSION"; export MAVERICKS_UPSTREAM_FILE
. "$SELF/msc.sh"
exec sh "$SHIPYARD/version.sh" "$@"
