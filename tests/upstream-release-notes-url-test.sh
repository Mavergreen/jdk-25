#!/bin/sh
# platform: host-agnostic
# usage: sh tests/upstream-release-notes-url-test.sh
#   build/upstream-release-notes-url.sh prints JBS's issue list for a jdk25u version's fixVersion, three
#   to five numeric parts, and refuses anything else (exit 2) with nothing on stdout.
set -eu
U="$(cd "$(dirname "$0")/.." && pwd)/build/upstream-release-notes-url.sh"
fail() { echo "FAIL $*"; exit 1; }
for v in 25.0.5 25.0.4.1 25.0.5.0.3 25.0.10; do
  got="$(sh "$U" "$v")" || fail "$v was refused"
  [ "$got" = "https://bugs.openjdk.org/issues/?jql=project%20%3D%20JDK%20AND%20fixVersion%20%3D%20$v" ] || fail "$v printed $got"
done
for bad in 25 25.0 25..5 25.0.5. .25.0.5 25.0.5.0.3.1 26.0.1 25.0.x 25.0.5-ga '25.0.5 x' ''; do
  rc=0; out="$(sh "$U" "$bad" 2>/dev/null)" || rc=$?
  [ "$rc" = 2 ] && [ -z "$out" ] || fail "'$bad': exit $rc, printed [$out]"
done
echo "PASS: upstream-release-notes-url"
