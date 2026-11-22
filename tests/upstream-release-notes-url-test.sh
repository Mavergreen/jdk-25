#!/bin/sh
# platform: host-agnostic
# usage: sh tests/upstream-release-notes-url-test.sh
#   build/upstream-release-notes-url.sh, offline: a file:// tree stands in for api.adoptium.net, and a
#   scratch git repository with release tags stands in for this checkout. It prints Temurin's release
#   notes page for the pinned GA build when Temurin has notes for it, and otherwise upstream's own
#   commits between the previous release's GA tag and this one, saying why on stderr. It refuses a
#   version that is not a jdk25u version (exit 2) with nothing on stdout.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
U="$HERE/build/upstream-release-notes-url.sh"
REAL_SHIPYARD="$(SHIPYARD_SCRIPTS="${SHIPYARD_SCRIPTS:-}" sh -c '. "$1/build/msc.sh" && printf "%s\n" "$SHIPYARD_SCRIPTS"' sh "$HERE")"
T="$(mktemp -d "${TMPDIR:-/tmp}/notes-url-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL $*"; exit 1; }

repo() {   # repo DIR REF TAG...: a checkout whose jdk pin is REF, carrying release tags TAG...
  mkdir -p "$1/components/jdk"
  v="${2#jdk-}"; v="${v%+*}"
  printf 'REPO=https://github.com/openjdk/jdk25u\nGA=jdk-%s-ga\nREF=%s\n' "$v" "$2" > "$1/components/jdk/version"
  ( cd "$1" && git init -q && git add -A \
      && git -c user.name=t -c user.email=t@t commit -qm pin && shift 2 \
      && for t in "$@"; do git tag "$t"; done )
}
notes() {  # notes RELEASE_NAME [ENTRIES]: Adoptium's release_notes answer for one release
  mkdir -p "$T/api/v3/info/release_notes"
  # platform: curl percent-decodes a file:// path, so jdk-25.0.5.1%2B2 reads the file named jdk-25.0.5.1+2
  printf '{\n    "id": "x",\n    "release_name": "%s",\n    "release_notes": [\n        %s\n    ]\n}\n' \
    "$1" "${2:-}" > "$T/api/v3/info/release_notes/$1"
}
run() {    # run ROOT VERSION: the hook's stdout, its stderr in $T/err
  MAVERICKS_ROOT="$1" ADOPTIUM_API="file://$T/api" SHIPYARD_SCRIPTS="$REAL_SHIPYARD" SHIPYARD_FETCH_TRIES=1 \
    sh "$U" "$2" 2> "$T/err"
}
ENTRY='{
            "id": "JDK-8395142",
            "link": "https://bugs.openjdk.org/browse/JDK-8395142",
            "title": "CA Enhancements"
        }'

repo "$T/a" jdk-25.0.5.1+2 25.0.4.1-mavericks.2 25.0.5.0.3-mavericks.4 25.0.5.0.3-mavericks.5
notes jdk-25.0.5.1+2 "$ENTRY"
got="$(run "$T/a" 25.0.5.1)" || fail "Temurin notes present: exit $?: $(cat "$T/err")"
[ "$got" = "https://adoptium.net/temurin/release-notes?version=jdk-25.0.5.1%2B2" ] \
  || fail "Temurin notes present: printed $got; the pin's GA build is +2, so Temurin's page for jdk-25.0.5.1+2"

notes jdk-25.0.5.1+2 ""
got="$(run "$T/a" 25.0.5.1)" || fail "Temurin notes empty: exit $?"
[ "$got" = "https://github.com/openjdk/jdk25u/compare/jdk-25.0.5.0.3-ga...jdk-25.0.5.1-ga" ] \
  || fail "Temurin notes empty: printed $got; an empty list is no notes, so upstream's commits since the previous release's GA"
grep -q 'Temurin' "$T/err" || fail "Temurin notes empty: stderr does not say why it fell back: $(cat "$T/err")"

rm -f "$T/api/v3/info/release_notes/jdk-25.0.5.1+2"
got="$(run "$T/a" 25.0.5.1)" || fail "Temurin release absent: exit $?"
[ "$got" = "https://github.com/openjdk/jdk25u/compare/jdk-25.0.5.0.3-ga...jdk-25.0.5.1-ga" ] \
  || fail "Temurin release absent: printed $got"
grep -q 'Temurin' "$T/err" || fail "Temurin release absent: stderr does not say why it fell back: $(cat "$T/err")"

repo "$T/first" jdk-25.0.5.1+2
got="$(run "$T/first" 25.0.5.1)" || fail "no earlier release: exit $?"
[ "$got" = "https://github.com/openjdk/jdk25u/commits/jdk-25.0.5.1-ga" ] \
  || fail "no earlier release: printed $got; with no previous GA to compare against, upstream's history at this GA"

repo "$T/later" jdk-25.0.5.1+2 25.0.5.0.3-mavericks.5 25.0.5.1-mavericks.1 25.0.10-mavericks.1
rm -f "$T/api/v3/info/release_notes/jdk-25.0.5.1+2"
got="$(run "$T/later" 25.0.5.1)" || fail "later releases tagged: exit $?"
[ "$got" = "https://github.com/openjdk/jdk25u/compare/jdk-25.0.5.0.3-ga...jdk-25.0.5.1-ga" ] \
  || fail "later releases tagged: printed $got; the baseline is the newest release of an EARLIER upstream, never this one's or a later one's"

notes jdk-25.0.6+3 "$ENTRY"
got="$(run "$T/a" 25.0.6)" || fail "version not the pin's: exit $?"
[ "$got" = "https://github.com/openjdk/jdk25u/compare/jdk-25.0.5.0.3-ga...jdk-25.0.6-ga" ] \
  || fail "version not the pin's: printed $got; the pin names no build for 25.0.6, so no Temurin page can be named"
grep -q 'components/jdk/version' "$T/err" || fail "version not the pin's: stderr does not name the pin: $(cat "$T/err")"

for bad in 25 25.0 25..5 25.0.5. .25.0.5 25.0.5.0.3.1 26.0.1 25.0.x 25.0.5-ga '25.0.5 x' ''; do
  rc=0; out="$(run "$T/a" "$bad")" || rc=$?
  [ "$rc" = 2 ] && [ -z "$out" ] || fail "'$bad': exit $rc, printed [$out]"
done
echo "PASS: upstream-release-notes-url"
