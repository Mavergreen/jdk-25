#!/bin/sh
# platform: host-agnostic
# usage: sh tests/patches-apply-test.sh
#   patches/ applies, in order and with no fuzz, to a fresh extraction of the source
#   components/jdk/version pins, by the applier build/build-jdk.sh uses (shipyard's apply_patches.sh).
#   A jdk25u bump that moves a patched hunk fails here, naming the patch, before any build starts.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
fail() { echo "FAIL $*" >&2; exit 1; }
. "$MAVERICKS_ROOT/build/msc.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/patches-apply-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

sh "$MAVERICKS_ROOT/build/fetch-jdk.sh" "$T/src" > "$T/fetch.out" 2>&1 \
  || { cat "$T/fetch.out" >&2; fail "could not fetch the pinned source"; }
sh "$SHIPYARD_SCRIPTS/apply_patches.sh" "$T/src" "$MAVERICKS_ROOT/patches" > "$T/apply.out" 2>&1 \
  || { cat "$T/apply.out" >&2; fail "patches/ does not apply to the pinned source"; }
want="$(cd "$MAVERICKS_ROOT/patches" && ls ./*.patch | wc -l | tr -d ' ')"
got="$(grep -c '^applying ' "$T/apply.out" || true)"
[ "$got" = "$want" ] || fail "apply_patches.sh applied $got of the $want patches in patches/"
if find "$T/src" \( -name '*.orig' -o -name '*.rej' \) | grep -q .; then
  fail "applying patches/ left .orig or .rej files"
fi
echo "PASS: patches-apply ($want patches)"
