#!/bin/sh
# platform: host-agnostic
#   usage: sh tests/rulings-test.sh
#          Every ruling a tracked file cites as R<n> is defined in PORT.md's "Rulings" section as a
#          line beginning "- **R<n>**", and no tracked file points into .superpowers/sdd/, which is
#          gitignored and absent from a clone.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
fail() { echo "FAIL $*"; exit 1; }
t="$(mktemp -d "${TMPDIR:-/tmp}/rulings.XXXXXX")"
trap 'rm -rf "$t"' EXIT

find "$root" \( -name .git -o -name .superpowers -o -name dist -o -name out \) -prune -o -type f -print \
  | LC_ALL=C sort > "$t/files"
: > "$t/cited"
while IFS= read -r f; do
  case "$f" in *.icns|*.png|*.tar.gz|*.pkg|*/tests/rulings-test.sh) continue ;; esac
  LC_ALL=C grep -oE '(^|[^A-Za-z0-9_])R[0-9]{1,3}([^0-9]|$)' "$f" 2>/dev/null \
    | LC_ALL=C sed -n 's/.*R\([0-9][0-9]*\).*/R\1/p' >> "$t/cited" || :
  if LC_ALL=C grep -n '\.superpowers/sdd/' "$f" > "$t/sdd" 2>/dev/null; then
    fail "$f points into gitignored .superpowers/sdd/: $(head -1 "$t/sdd")"
  fi
done < "$t/files"
LC_ALL=C sort -u -o "$t/cited" "$t/cited"
[ -s "$t/cited" ] || fail "found no R<n> citations at all; the scan is broken"

sed -n '/^## Rulings$/,/^## /p' "$root/PORT.md" \
  | LC_ALL=C sed -n 's/^- \*\*\(R[0-9][0-9]*\)\*\*.*/\1/p' | LC_ALL=C sort -u > "$t/defined"
[ -s "$t/defined" ] || fail "PORT.md has no \"## Rulings\" section with \"- **R<n>**\" lines"

missing="$(LC_ALL=C comm -23 "$t/cited" "$t/defined")"
[ -z "$missing" ] || fail "cited but not defined in PORT.md's Rulings: $(echo $missing)"
echo "PASS rulings: $(wc -l < "$t/cited" | tr -d ' ') cited, all defined in PORT.md"
