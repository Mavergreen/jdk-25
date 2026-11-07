#!/bin/sh
# platform: host-agnostic
# usage: sh tests/resolve-ga-test.sh
#   scripts/resolve-ga.sh turns components/jdk/version's GA (a jdk25u -ga tag, which Renovate moves) into
#   the REF and DIGEST every build uses: DIGEST is the commit the GA tag names, REF the jdk-<version>+<N>
#   build tag on that commit with the highest N. --check exits 0 when the file already holds them, 3
#   when it holds others (stale), 1 on any error; the write changes REF and DIGEST and nothing else. A GA
#   that is not a jdk-25 -ga tag, one jdk25u does not have, or one on a commit with no build tag of its
#   version is refused, writing nothing. Offline: RESOLVE_GA_TAGS stands in for git ls-remote with
#   tests/fixtures/jdk25u-ls-remote-tags.txt, real jdk25u refs that include EA builds (jdk-25.0.6+1) and
#   the CA respins (25.0.5.0.2, 25.0.5.0.3).
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/resolve-ga.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/components/jdk"
cp "$REPO/scripts/resolve-ga.sh" "$T/scripts/"
V="$T/components/jdk/version"
RESOLVE_GA_TAGS="$REPO/tests/fixtures/jdk25u-ls-remote-tags.txt"; export RESOLVE_GA_TAGS
pinfile() { printf 'REPO=https://github.com/openjdk/jdk25u\nGA=%s\nREF=%s\nDIGEST=%s\nTARBALL_SHA256=%s\n' "$1" "$2" "$3" \
  0000000000000000000000000000000000000000000000000000000000000000 > "$V"; }
rg() { sh "$T/scripts/resolve-ga.sh" "$@"; }

echo "-- each GA resolves to its commit and that commit's build tag of its own version"
for c in "jdk-25.0.5-ga jdk-25.0.5+8 fda231468e56663992785ec199a6efb8eca3cc7a" \
         "jdk-25.0.5.0.2-ga jdk-25.0.5.0.2+1 1775ea114f649f0314e4e43eb6c802ff16dfab7c" \
         "jdk-25.0.5.0.3-ga jdk-25.0.5.0.3+1 275848b087112429235f4f235822e294a1a288ef" \
         "jdk-25.0.4.1-ga jdk-25.0.4.1+1 7b65d74bcbd7c3a0b4c1f5c5bd85e64aa2e51b4a"; do
  set -- $c
  pinfile "$1" jdk-25.0.4+0 0000000000000000000000000000000000000000
  rc=0; rg --check > "$T/out" 2>&1 || rc=$?
  [ "$rc" = 3 ] || fail "$1: --check on a stale pin exited $rc, not 3: $(cat "$T/out")"
  rg > "$T/out" 2>&1 || fail "$1: the write failed: $(cat "$T/out")"
  grep -qx "REF=$2" "$V" && grep -qx "DIGEST=$3" "$V" || fail "$1: wrote $(grep -E '^(REF|DIGEST)=' "$V" | tr '\n' ' '), not REF=$2 DIGEST=$3"
  grep -qx "GA=$1" "$V" && grep -qx 'REPO=https://github.com/openjdk/jdk25u' "$V" && grep -q '^TARBALL_SHA256=0' "$V" \
    || fail "$1: the write changed more than REF and DIGEST"
  rc=0; rg --check > "$T/out" 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "$1: --check after the write exited $rc, not 0: $(cat "$T/out")"
done

echo "-- refused, writing nothing: not a jdk-25 -ga tag, a tag jdk25u lacks, an EA build, a bad pin file"
for bad in jdk-25.0.6+1 jdk-25.0.6-ga jdk-25.0.5.1-ga jdk-26.0.1-ga jdk-25.0.5 'jdk-25.0.5-ga;x' ''; do
  pinfile "$bad" jdk-25.0.5+8 fda231468e56663992785ec199a6efb8eca3cc7a; cp "$V" "$T/before"
  for mode in --check write; do
    rc=0; if [ "$mode" = write ]; then rg > "$T/out" 2>&1 || rc=$?; else rg --check > "$T/out" 2>&1 || rc=$?; fi
    [ "$rc" = 1 ] || fail "GA '$bad' ($mode): exit $rc, not 1: $(cat "$T/out")"
    cmp -s "$T/before" "$V" || fail "GA '$bad' ($mode) changed the pin file"
  done
done
printf 'REPO=https://github.com/openjdk/jdk25u\nREF=jdk-25.0.5+8\nDIGEST=x\n' > "$V"
if rg --check > /dev/null 2>&1; then fail "a pin file with no GA line passed --check"; fi
echo "-- an ls-remote that fails is an error, never a stale or current pin"
pinfile jdk-25.0.5-ga jdk-25.0.5+8 fda231468e56663992785ec199a6efb8eca3cc7a
rc=0; RESOLVE_GA_TAGS="$T/missing" rg --check > "$T/out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "a missing tag list: --check exit $rc, not 1"
echo "PASS: resolve-ga"
