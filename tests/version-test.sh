#!/bin/sh
# platform: host-agnostic
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../build/version.sh"
U="$(sh "$here/../build/derive-upstream-version.sh" --print)"

out="$(MAVERICKS_TAGS='' sh "$script" auto)"
printf '%s\n' "$out" | grep -q "^FULL=${U}-mavericks.1$"  || { echo "FAIL auto/new FULL: $out"; exit 1; }
printf '%s\n' "$out" | grep -q "^TAG=${U}-mavericks.1$"   || { echo "FAIL auto/new TAG: $out"; exit 1; }
printf '%s\n' "$out" | grep -q '^RELEASE=yes$'            || { echo "FAIL auto/new REL: $out"; exit 1; }

out="$(MAVERICKS_TAGS="${U}-mavericks.1
${U}-mavericks.3
${U}-mavericks.2" sh "$script" auto)"
printf '%s\n' "$out" | grep -q "^FULL=${U}-mavericks.3$"  || { echo "FAIL auto/exist FULL: $out"; exit 1; }
printf '%s\n' "$out" | grep -q '^RELEASE=no$'             || { echo "FAIL auto/exist REL: $out"; exit 1; }

out="$(MAVERICKS_TAGS="${U}-mavericks.3" sh "$script" local)"
printf '%s\n' "$out" | grep -q "^FULL=${U}-mavericks.4$"  || { echo "FAIL local FULL: $out"; exit 1; }
printf '%s\n' "$out" | grep -q '^RELEASE=yes$'            || { echo "FAIL local REL: $out"; exit 1; }

echo "PASS: version"
