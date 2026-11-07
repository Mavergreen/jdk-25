#!/bin/sh
# platform: host-agnostic
#   usage: sh tests/derive-upstream-version-test.sh
#          build/derive-upstream-version.sh turns components/jdk/version's REF into UPSTREAM_VERSION:
#          the version of a GA build tag, three to five parts, written to the file and printed;
#          --print prints it and writes nothing; a malformed REF is refused and the file is left alone.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
D="$here/../build/derive-upstream-version.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/derive-upstream.XXXXXX")"
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $*"; exit 1; }
mkdir -p "$t/build" "$t/components/jdk"
cp "$D" "$t/build/"
pin() {  # pin <REF> [<GA>]: GA defaults to REF's own -ga tag
  _ga="${2-$(printf '%s' "$1" | sed 's/+[0-9]*$/-ga/')}"
  printf 'REPO=https://github.com/openjdk/jdk25u\nGA=%s\nREF=%s\nDIGEST=7b65d74bcbd7c3a0b4c1f5c5bd85e64aa2e51b4a\nTARBALL_SHA256=0\n' "$_ga" "$1" > "$t/components/jdk/version"
}

for c in "jdk-25.0.4.1+1 25.0.4.1" "jdk-25.0.5+8 25.0.5" "jdk-25.0.5.0.3+1 25.0.5.0.3" "jdk-25.0.10+12 25.0.10"; do
  ref="${c% *}"; want="${c#* }"
  pin "$ref"; rm -f "$t/UPSTREAM_VERSION"
  got="$(sh "$t/build/derive-upstream-version.sh")" || fail "$ref was refused"
  [ "$got" = "$want" ] || fail "$ref printed $got, not $want"
  [ "$(cat "$t/UPSTREAM_VERSION")" = "$want" ] || fail "$ref wrote '$(cat "$t/UPSTREAM_VERSION")', not $want"
done
pin jdk-25.0.5+8; rm -f "$t/UPSTREAM_VERSION"
[ "$(sh "$t/build/derive-upstream-version.sh" --print)" = 25.0.5 ] || fail "--print did not print 25.0.5"
[ ! -e "$t/UPSTREAM_VERSION" ] || fail "--print wrote UPSTREAM_VERSION"

echo 25.0.4.1 > "$t/UPSTREAM_VERSION"
for bad in jdk-25.0.5 jdk-25+36 jdk-25.0.5+ jdk-25.0.5+8-ga jdk-25.0.5-ga jdk-25.0.5-ea+3 jdk-26.0.1+2 \
  jdk-25.0.5.0.3.1+1 jdk-25..5+8 jdk-25.0.x+8 25.0.5+8 ''; do
  pin "$bad"
  if sh "$t/build/derive-upstream-version.sh" > "$t/o" 2>&1; then fail "REF '$bad' was not refused: $(cat "$t/o")"; fi
  grep -q "REF '$bad' is not" "$t/o" || fail "the refusal of '$bad' does not name it: $(cat "$t/o")"
  [ "$(cat "$t/UPSTREAM_VERSION")" = 25.0.4.1 ] || fail "a refused REF '$bad' changed UPSTREAM_VERSION"
done
# spec: PORT.md ruling R46 -- a Renovate bump moves GA alone;
#       until the pins bot fills REF from it, every build refuses to start
for c in "jdk-25.0.5.0.3+1 jdk-25.0.6-ga" "jdk-25.0.5.0.3+1 jdk-25.0.5-ga" "jdk-25.0.5+8 jdk-25.0.5.0.3-ga" "jdk-25.0.5+8 ''"; do
  ref="${c% *}"; ga="${c#* }"; [ "$ga" = "''" ] && ga=""
  pin "$ref" "$ga"
  if sh "$t/build/derive-upstream-version.sh" > "$t/o" 2>&1; then fail "REF $ref with GA '$ga' was not refused"; fi
  grep -q "GA '$ga'" "$t/o" || fail "the GA refusal for REF $ref, GA '$ga' does not name GA: $(cat "$t/o")"
  [ "$(cat "$t/UPSTREAM_VERSION")" = 25.0.4.1 ] || fail "a refused GA '$ga' changed UPSTREAM_VERSION"
done
printf 'REPO=x\nDIGEST=0\n' > "$t/components/jdk/version"
if sh "$t/build/derive-upstream-version.sh" > "$t/o" 2>&1; then fail "a pin with no REF line was not refused"; fi
grep -q "REF '' is not" "$t/o" || fail "the refusal of a pin with no REF line does not name REF: $(cat "$t/o")"
[ "$(cat "$t/UPSTREAM_VERSION")" = 25.0.4.1 ] || fail "a pin with no REF line changed UPSTREAM_VERSION"
echo "PASS: derive-upstream-version"
