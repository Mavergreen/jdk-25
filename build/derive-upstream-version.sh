#!/bin/sh
# platform: host-agnostic
#   usage: derive-upstream-version.sh [--print]
#          Reads REF from components/jdk/version (a jdk25u GA build tag: jdk-25.0.4.1+1,
#          jdk-25.0.5+8, jdk-25.0.5.0.3+1) and prints this product's upstream version (25.0.4.1,
#          25.0.5, 25.0.5.0.3), writing it to UPSTREAM_VERSION. With --print it writes nothing. A
#          REF of any other shape is refused, and so is one whose version is not GA's (jdk-<version>-ga);
#          either way UPSTREAM_VERSION is left as it was.
# spec: INGREDIENTS.md "Declared state" -- upstream is components/jdk/version:GA, the one value
#       Renovate moves; UPSTREAM_VERSION, version.sh's input, is derived here from REF, which must be GA's
# spec: tests/derive-upstream-version-test.sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ref="$(sed -n 's/^REF=//p' "$ROOT/components/jdk/version" 2>/dev/null)"
refuse() { echo "derive-upstream-version: REF '$ref' is not a jdk25u build tag: jdk-25.<interim>.<update>, then up to two more .<number> parts, then +<build>" >&2; exit 1; }
case "$ref" in jdk-25.*+*) : ;; *) refuse ;; esac
v="${ref#jdk-}"; b="${v##*+}"; v="${v%+*}"
case "$b" in ''|*[!0-9]*) refuse ;; esac
case "$v" in ''|*[!0-9.]*|.*|*.|*..*) refuse ;; esac
case "$v" in
  25.*.*.*.*.*) refuse ;;
  25.*.*) : ;;
  *) refuse ;;
esac
# spec: PORT.md ruling R46 -- Renovate moves GA, a jdk25u GA
#       tag, and the pins bot then fills REF from it; a REF of another version is a bump not yet filled
#       (or an EA build), so nothing derives a version from it and every build stops here
ga="$(sed -n 's/^GA=//p' "$ROOT/components/jdk/version" 2>/dev/null)"
[ "$ga" = "jdk-$v-ga" ] || {
  echo "derive-upstream-version: GA '$ga' is not REF $ref's GA tag (jdk-$v-ga); run sh scripts/resolve-ga.sh and sh scripts/pin-source-tarballs.sh, as the pins bot does on a Renovate branch" >&2
  exit 1; }
if [ "${1:-}" = --print ]; then printf '%s\n' "$v"; exit 0; fi
printf '%s\n' "$v" > "$ROOT/UPSTREAM_VERSION"
printf '%s\n' "$v"
