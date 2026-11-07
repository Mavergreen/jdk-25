#!/bin/sh
# platform: host-agnostic
#   usage: sh build/fetch-jdk.sh DEST
#          Replaces DEST with a fresh extraction of the JDK source pinned in components/jdk/version
#          (REPO, DIGEST, TARBALL_SHA256), by shipyard's fetch_pinned_source.sh: no git needed, so this
#          runs on a native OS X 10.9 host. On a checksum mismatch it exits non-zero naming the SHA-256
#          it got. JDK_PIN_FILE replaces the pin file (the tests).
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
[ $# -eq 1 ] || { echo "usage: fetch-jdk.sh DEST" >&2; exit 2; }
MAVERICKS_ROOT="$(cd "$SELF/.." && pwd)"; export MAVERICKS_ROOT
. "$SELF/msc.sh"
PIN="${JDK_PIN_FILE:-$MAVERICKS_ROOT/components/jdk/version}"
. "$PIN"
exec sh "$SHIPYARD/fetch_pinned_source.sh" "$REPO" "$DIGEST" "$TARBALL_SHA256" "$1"
