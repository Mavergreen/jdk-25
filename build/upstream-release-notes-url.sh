#!/bin/sh
# platform: host-agnostic
#   usage: upstream-release-notes-url.sh <upstream-version>
#          Prints where to read what changed in that jdk25u release (such as 25.0.5.1). jdk25u
#          publishes no release notes of its own, so: Eclipse Temurin's list of the OpenJDK issues in
#          its build of that release, adoptium.net/temurin/release-notes?version=jdk-<version>+<build>,
#          when api.adoptium.net has a non-empty list for it. <build> is REF's in components/jdk/version,
#          which names GA's build (build/derive-upstream-version.sh refuses any other). Otherwise, saying
#          why on stderr, upstream's own commits between the previous release's GA tag and this one's
#          (github.com/openjdk/jdk25u/compare/jdk-<previous>-ga...jdk-<version>-ga), or with no earlier
#          release, upstream's history at this GA tag. Exit 2, printing nothing, for a version that is
#          not 25.<interim>.<update> plus up to two more numeric parts. MAVERICKS_ROOT replaces this
#          checkout's root and ADOPTIUM_API https://api.adoptium.net (the tests). Needs shipyard (msc.sh),
#          and git with the release tags for the previous release.
# spec: tests/upstream-release-notes-url-test.sh
set -eu
[ "$#" -eq 1 ] || { echo "usage: upstream-release-notes-url.sh <upstream-version>" >&2; exit 2; }
v="$1"
refuse() { echo "upstream-release-notes-url: '$v' is not a jdk25u version (25.<interim>.<update>, then up to two more numeric parts)" >&2; exit 2; }
case "$v" in ''|*[!0-9.]*|.*|*.|*..*|25.*.*.*.*.*) refuse ;; esac
case "$v" in 25.*.*) : ;; *) refuse ;; esac

here="$(cd "$(dirname "$0")/.." && pwd)"
root="${MAVERICKS_ROOT:-$here}"
api="${ADOPTIUM_API:-https://api.adoptium.net}"
. "$here/build/msc.sh"
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
say() { echo "upstream-release-notes-url: $*" >&2; }

. "$SHIPYARD_SCRIPTS/lib/vercmp.sh"

previous_upstream() {
  _best=""
  for _t in $(cd "$root" && git tag -l '*-mavericks.*'); do
    _u="${_t%-mavericks.*}"
    numeric "$_u" || continue
    [ "$(ver_cmp "$_u" "$v")" = -1 ] || continue
    [ -z "$_best" ] || [ "$(ver_cmp "$_u" "$_best")" = 1 ] || continue
    _best="$_u"
  done
  printf '%s\n' "$_best"
}

upstream_commits() {
  prev="$(previous_upstream)"
  if [ -n "$prev" ]; then
    printf 'https://github.com/openjdk/jdk25u/compare/jdk-%s-ga...jdk-%s-ga\n' "$prev" "$v"
  else
    say "no earlier release to compare against; linking upstream's history at jdk-$v-ga"
    printf 'https://github.com/openjdk/jdk25u/commits/jdk-%s-ga\n' "$v"
  fi
}

ref="$(sed -n 's/^REF=//p' "$root/components/jdk/version" 2>/dev/null)"
case "$ref" in
  "jdk-$v+"*) build="${ref#jdk-"$v"+}" ;;
  *) build="" ;;
esac
case "$build" in
  ''|*[!0-9]*)
    say "components/jdk/version's REF '$ref' is not a build of $v, so no Temurin build can be named; linking upstream's commits"
    upstream_commits; exit 0 ;;
esac

name="jdk-$v%2B$build"
body="$(shipyard_curl --quiet "$api/v3/info/release_notes/$name" - 2>/dev/null)" || body=""
body="$(printf '%s' "$body" | tr -d ' \t\r\n')"
case "$body" in
  *'"release_notes":[{'*)
    printf 'https://adoptium.net/temurin/release-notes?version=%s\n' "$name" ;;
  *)
    say "Temurin has no release notes for jdk-$v+$build ($api/v3/info/release_notes/$name); linking upstream's commits"
    upstream_commits ;;
esac
