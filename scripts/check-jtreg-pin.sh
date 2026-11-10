#!/bin/sh
# platform: host-agnostic
#   usage: sh scripts/check-jtreg-pin.sh [--conf FILE]
#          Fails, naming both, when components/jtreg/version's TAG is not the jtreg the pinned jdk source's
#          own CI runs: JTREG_VERSION in its make/conf/github-actions.conf, read at components/jdk/version's
#          DIGEST from GitHub (or from FILE). tests/jtreg.sh refuses the same mismatch, but only once the
#          gate starts on 10.9; this lets a jdk bump that left jtreg behind fail in minutes, before a build.
#          Renovate cannot move the jtreg pin for it: the version it must match is a value inside the
#          pinned source, which no Renovate datasource reads, so the pins bot does (scripts/pin-jtreg.sh,
#          ruling R48); this stays the guard for a bump the bot could not fill. Exits 0 when they
#          agree, 1 otherwise, 2 usage.
#          Needs curl (shipyard_curl) without --conf.
# spec: tests/check-jtreg-pin-test.sh
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "check-jtreg-pin: $*" >&2; exit 1; }
conf=""
case "$#:${1:-}" in
  0:) ;;
  2:--conf) conf="$2" ;;
  *) echo "usage: sh scripts/check-jtreg-pin.sh [--conf FILE]" >&2; exit 2 ;;
esac
pin="$(sed -n 's/^TAG=jtreg-//p' "$HERE/components/jtreg/version")"
[ -n "$pin" ] || fail "components/jtreg/version has no TAG=jtreg-<version>"
if [ -z "$conf" ]; then
  repo="$(sed -n 's/^REPO=//p' "$HERE/components/jdk/version")"
  digest="$(sed -n 's/^DIGEST=//p' "$HERE/components/jdk/version")"
  case "$repo" in https://github.com/*/*) : ;; *) fail "components/jdk/version's REPO '$repo' is not a GitHub repository" ;; esac
  case "$digest" in *[!0-9a-f]*|'') fail "components/jdk/version's DIGEST '$digest' is not a commit" ;; esac
  . "$HERE/build/msc.sh"
  . "$SHIPYARD/mavericks_fetch.sh"
  T="$(mktemp -d "${TMPDIR:-/tmp}/check-jtreg-pin.XXXXXX")"
  trap 'rm -rf "$T"' EXIT
  conf="$T/github-actions.conf"
  shipyard_curl "https://raw.githubusercontent.com/${repo#https://github.com/}/$digest/make/conf/github-actions.conf" "$conf" \
    || fail "could not fetch make/conf/github-actions.conf at $digest"
fi
[ -f "$conf" ] || fail "no $conf"
want="$(sed -n 's/^JTREG_VERSION=//p' "$conf" | tr -d ' \t\r')"
[ -n "$want" ] || fail "make/conf/github-actions.conf names no JTREG_VERSION"
[ "$pin" = "$want" ] || fail "components/jtreg/version pins jtreg $pin, but the jdk source's own CI runs jtreg $want; move the pin to jtreg-$want (TAG and the SHA-256 of GitHub's tarball of it)"
echo "check-jtreg-pin: jtreg $pin, as the jdk source's own CI runs"
