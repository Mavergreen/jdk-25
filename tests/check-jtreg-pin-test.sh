#!/bin/sh
# platform: host-agnostic
# usage: sh tests/check-jtreg-pin-test.sh
#   scripts/check-jtreg-pin.sh compares components/jtreg/version's TAG with the JTREG_VERSION the pinned
#   jdk source's make/conf/github-actions.conf names: 0 when they agree; 1, naming both, when they do not
#   or either is missing. Offline: --conf names a stand-in github-actions.conf.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
C="$here/../scripts/check-jtreg-pin.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/check-jtreg-pin.XXXXXX")"
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $*"; exit 1; }
pin="$(sed -n 's/^TAG=jtreg-//p' "$here/../components/jtreg/version")"
[ -n "$pin" ] || fail "components/jtreg/version has no TAG=jtreg-..."
printf 'JTREG_MIN_VERSION=8\nJTREG_VERSION=%s\nGTEST_VERSION=1.14.0\n' "$pin" > "$t/agree"
sh "$C" --conf "$t/agree" > "$t/o" 2>&1 || fail "an agreeing conf was refused: $(cat "$t/o")"
for other in 8+2 8.2+1 8.2.1+2; do
  printf 'JTREG_VERSION=%s\n' "$other" > "$t/c"
  if sh "$C" --conf "$t/c" > "$t/o" 2>&1; then fail "JTREG_VERSION '$other' against the pin $pin passed"; fi
  grep -qF "jtreg $pin" "$t/o" || fail "the refusal of '$other' does not name the pin: $(cat "$t/o")"
done
printf 'JTREG_VERSION=\nGTEST_VERSION=1.14.0\n' > "$t/none"
if sh "$C" --conf "$t/none" > "$t/o" 2>&1; then fail "a conf with no JTREG_VERSION passed"; fi
if sh "$C" --conf "$t/missing" > "$t/o" 2>&1; then fail "a missing conf passed"; fi
echo "PASS: check-jtreg-pin"
