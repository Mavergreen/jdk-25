#!/bin/sh
# platform: host-agnostic
#   usage: sh tests/fetch-previous-release-test.sh
#          Drives scripts/fetch-previous-release.sh against a file:// release tree (MAVERGREEN_RELEASES)
#          and a fixture pin (MAVERICKS_ROOT): a pinned tag fetches jdk-<tag>.pkg, verified, into DIR;
#          `none` fetches nothing and says so; an empty or malformed pin, a release without the pkg and a
#          pkg whose bytes SHA256SUMS does not list all fail. Needs SHIPYARD_SCRIPTS.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "FAIL $*" >&2; exit 1; }
[ -n "${SHIPYARD_SCRIPTS:-}" ] && [ -r "$SHIPYARD_SCRIPTS/fetch-release-pkg.sh" ] \
  || { echo "SKIP: needs SHIPYARD_SCRIPTS with fetch-release-pkg.sh"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/fetch-previous-release-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
tag=25.0.5.0.3-mavericks.4
rel="$T/rel/Mavergreen/jdk-25/releases/download/$tag"
mkdir -p "$rel" "$T/root/components/previous-release"
echo "the previous pkg" > "$rel/jdk-$tag.pkg"
(cd "$rel" && shasum -a 256 "jdk-$tag.pkg" > SHA256SUMS)

n=0
run() {
  n=$((n + 1)); rc=0
  printf '%s\n' "$1" > "$T/root/components/previous-release/version"
  rm -rf "$T/dl"
  MAVERICKS_ROOT="$T/root" MAVERGREEN_RELEASES="file://$T/rel" \
    sh "$here/../scripts/fetch-previous-release.sh" "$T/dl" > "$T/out" 2>&1 || rc=$?
  out="$(cat "$T/out")"
}
expect() {
  [ "$rc" -eq "$2" ] || fail "$1: exit $rc, not $2: $out"
  printf '%s\n' "$out" | grep -F -- "$3" > /dev/null || fail "$1: no '$3' in: $out"
  echo "ok $1"
}

run "$tag"; expect "a pinned tag fetches its pkg" 0 "$T/dl/jdk-$tag.pkg"
cmp -s "$rel/jdk-$tag.pkg" "$T/dl/jdk-$tag.pkg" || fail "the fetched pkg is not the release's"
run none; expect "none fetches nothing and says so" 0 "no previous release pinned"
[ ! -e "$T/dl" ] || [ -z "$(ls -A "$T/dl")" ] || fail "none fetched something: $(ls -A "$T/dl")"
run ""; expect "an empty pin fails" 1 "neither none nor a release tag"
run "latest"; expect "a pin that is not a tag fails" 1 "neither none nor a release tag"
run "25.0.5.0.3-mavericks.9"; expect "a release that does not exist fails" 1 "fetch-release-pkg"
echo "something else" > "$rel/jdk-$tag.pkg"
run "$tag"; expect "a pkg whose checksum does not match fails" 1 "could not fetch and verify"
rm "$T/root/components/previous-release/version"
rc=0; MAVERICKS_ROOT="$T/root" sh "$here/../scripts/fetch-previous-release.sh" "$T/dl" > "$T/out" 2>&1 || rc=$?
out="$(cat "$T/out")"; n=$((n + 1)); expect "a missing pin fails" 1 "no readable"
echo "PASS: fetch-previous-release-test ($n cases)"
