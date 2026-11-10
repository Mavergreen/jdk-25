#!/bin/sh
# platform: host-agnostic -- runs on the CI runner, before the 10.9 guest starts, so the guest needs no gh or token
#   usage: sh scripts/fetch-previous-release.sh DIR
#          Fetches jdk-<tag>.pkg of the release components/previous-release/version pins into DIR,
#          with shipyard's fetch-release-pkg.sh, verified against that release's SHA256SUMS, and prints
#          its path. With the pin reading `none`, fetches nothing and says so on stderr. Exit 1 on an
#          unreadable, empty or malformed pin, or a failed fetch or checksum; 2 on bad usage.
#          MAVERICKS_ROOT replaces this checkout's root and MAVERGREEN_RELEASES https://github.com
#          (the tests).
# spec: PORT.md ruling R52 -- tests/smoke-mavericks.sh installs this pkg first, from DIR
set -eu
[ "$#" -eq 1 ] && [ -n "$1" ] || { echo "usage: sh $0 DIR" >&2; exit 2; }
here="$(cd "$(dirname "$0")/.." && pwd)"
root="${MAVERICKS_ROOT:-$here}"
. "$here/tests/lib/previous-release.sh"
prev="$(previous_release_tag "$root")" || exit 1
if [ "$prev" = none ]; then
  echo "fetch-previous-release: no previous release pinned; tests/smoke-mavericks.sh will say it skipped the upgrade leg" >&2
  exit 0
fi
[ -n "${SHIPYARD_SCRIPTS:-}" ] || { echo "fetch-previous-release: SHIPYARD_SCRIPTS is unset" >&2; exit 1; }
sh "$SHIPYARD_SCRIPTS/fetch-release-pkg.sh" jdk-25 "$prev" "jdk-$prev.pkg" "$1"
