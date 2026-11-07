#!/bin/sh
# platform: host-agnostic
#   Offline: MAVERICKS_CODELOAD serves a file:// tree holding a fixture tarball laid out as codeload
#   lays out GitHub's (OWNER/NAME/tar.gz/DIGEST); JDK_PIN_FILE points fetch-jdk.sh at a fixture pin.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../build/fetch-jdk.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/fetch-jdk-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

D=0123456789abcdef0123456789abcdef01234567
mkdir -p "$T/pkg/jdk25u-$D/src" "$T/serve/openjdk/jdk25u/tar.gz"
echo hello > "$T/pkg/jdk25u-$D/src/file.txt"
tar czf "$T/serve/openjdk/jdk25u/tar.gz/$D" -C "$T/pkg" "jdk25u-$D"
SHA="$(shasum -a 256 < "$T/serve/openjdk/jdk25u/tar.gz/$D" | cut -c1-64)"

pin() {  # pin FILE SHA256
  printf 'REPO=https://github.com/openjdk/jdk25u\nREF=jdk-25.0.0+0\nDIGEST=%s\nTARBALL_SHA256=%s\n' "$D" "$2" > "$1"
}
export MAVERICKS_CODELOAD="file://$T/serve" SHIPYARD_FETCH_BACKOFF=0 SHIPYARD_FETCH_TRIES=1
export MAVERICKS_SOURCE_CACHE="$T/cache"

pin "$T/good" "$SHA"
JDK_PIN_FILE="$T/good" sh "$script" "$T/out" 2>"$T/err" || { cat "$T/err"; echo "FAIL match: exit non-zero"; exit 1; }
[ "$(cat "$T/out/src/file.txt")" = hello ] || { echo "FAIL match: not extracted"; exit 1; }
grep -q "^https://github.com/openjdk/jdk25u $D $SHA\$" "$T/out/.mavergreen-source" || { echo "FAIL match: no source record"; exit 1; }

BAD=0000000000000000000000000000000000000000000000000000000000000000
pin "$T/bad" "$BAD"
rm -rf "$T/cache" "$T/out2"
if JDK_PIN_FILE="$T/bad" sh "$script" "$T/out2" 2>"$T/err"; then echo "FAIL mismatch: exit 0"; exit 1; fi
grep -q "$SHA" "$T/err" || { cat "$T/err"; echo "FAIL mismatch: stderr does not name $SHA"; exit 1; }
[ ! -e "$T/out2" ] || { echo "FAIL mismatch: DEST created"; exit 1; }

echo "PASS: fetch-jdk"
