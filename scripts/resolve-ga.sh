#!/bin/sh
# platform: host-agnostic
#   usage: sh scripts/resolve-ga.sh [--check]
#          Writes into components/jdk/version the REF and DIGEST its GA names. GA is a jdk25u GA tag
#          (jdk-25.0.5-ga, or a CA respin's jdk-25.0.5.0.3-ga), the one source pin Renovate moves.
#          DIGEST is the commit that tag names; REF is the build tag of the same version on that commit
#          with the highest build number (jdk-25.0.5+8), which configure's --with-version-build reads.
#          --check writes nothing, and fails naming the pins when they are not GA's. The file is written
#          once, by a rename from beside it, changing REF and DIGEST and nothing else.
#          Exits, as scripts/pin-source-tarballs.sh's (the pins bot relies on them): 0 the pins are GA's
#          (or were just written); 3 --check found pins that are not; 1 any failure (a GA that is not a
#          jdk-25 -ga tag, a tag jdk25u lacks, no build tag of its version on its commit, a failed
#          ls-remote); 2 usage.
#          Needs git (git ls-remote of REPO). RESOLVE_GA_TAGS names a file of ls-remote output to read
#          instead (the tests).
# spec: tests/resolve-ga-test.sh
set -eu
CHECK=0
case "$#:${1:-}" in
  0:) ;;
  1:--check) CHECK=1 ;;
  *) echo "usage: sh scripts/resolve-ga.sh [--check]" >&2; exit 2 ;;
esac
fail() { echo "resolve-ga: $*" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PINFILE="$HERE/components/jdk/version"
repo="$(sed -n 's/^REPO=//p' "$PINFILE")"
ga="$(sed -n 's/^GA=//p' "$PINFILE")"
ref="$(sed -n 's/^REF=//p' "$PINFILE")"
digest="$(sed -n 's/^DIGEST=//p' "$PINFILE")"
case "$ga" in jdk-25.*-ga) : ;; *) fail "components/jdk/version's GA is '$ga', not a jdk-25.<interim>.<update>... -ga tag" ;; esac
v="${ga#jdk-}"; v="${v%-ga}"
case "$v" in ''|*[!0-9.]*|.*|*.|*..*|25.*.*.*.*.*) fail "GA '$ga' does not carry a jdk25u version" ;; esac
case "$v" in 25.*.*) : ;; *) fail "GA '$ga' does not carry a jdk25u version" ;; esac
if [ -n "${RESOLVE_GA_TAGS:-}" ]; then
  tags="$(cat "$RESOLVE_GA_TAGS")" || fail "cannot read $RESOLVE_GA_TAGS"
else
  case "$repo" in https://github.com/*/*) : ;; *) fail "components/jdk/version's REPO is '$repo', not a GitHub repository" ;; esac
  tags="$(git ls-remote --tags "$repo")" || fail "git ls-remote --tags $repo failed"
fi
[ -n "$tags" ] || fail "no tags listed for $repo"
# platform: an annotated tag lists twice, as its own object and, with ^{}, as the commit it names;
#           the commit is what a build fetches, so the ^{} line wins.
commit_of() {
  printf '%s\n' "$tags" | awk -v t="refs/tags/$1" '$2 == t { c = $1 } $2 == t "^{}" { p = $1 } END { print (p != "" ? p : c) }'
}
gac="$(commit_of "$ga")"
case "$gac" in ''|*[!0-9a-f]*) fail "$repo has no tag $ga" ;; esac
[ "${#gac}" -eq 40 ] || fail "$repo's $ga names '$gac', not a commit"
newref="$(printf '%s\n' "$tags" | awk -v pre="refs/tags/jdk-$v+" -v c="$gac" '
  { n = $2; peeled = 0
    if (substr(n, length(n) - 2) == "^{}") { n = substr(n, 1, length(n) - 3); peeled = 1 }
    if (index(n, pre) != 1) next
    b = substr(n, length(pre) + 1); if (b == "" || b ~ /[^0-9]/) next
    if (peeled) p[b] = $1; else o[b] = $1 }
  END { best = -1
        for (b in o) { s = (b in p) ? p[b] : o[b]; if (s == c && b + 0 > best) best = b + 0 }
        for (b in p) { if (p[b] == c && b + 0 > best) best = b + 0 }
        if (best >= 0) print "jdk-" substr(pre, length("refs/tags/jdk-") + 1) best }')"
[ -n "$newref" ] || fail "$repo has no jdk-$v+<build> tag on $ga's commit $gac"
if [ "$CHECK" = 1 ]; then
  if [ "$ref" = "$newref" ] && [ "$digest" = "$gac" ]; then exit 0; fi
  echo "resolve-ga: components/jdk/version has REF=$ref DIGEST=$digest, but $ga is REF=$newref DIGEST=$gac -- run sh scripts/resolve-ga.sh, then sh scripts/pin-source-tarballs.sh" >&2
  exit 3
fi
if [ "$ref" = "$newref" ] && [ "$digest" = "$gac" ]; then echo "components/jdk/version: REF and DIGEST are $ga's"; exit 0; fi
grep -q '^REF=' "$PINFILE" && grep -q '^DIGEST=' "$PINFILE" || fail "components/jdk/version has no REF= or DIGEST= line"
NEW="$PINFILE.new.$$"
trap 'rm -f "$NEW"' EXIT
awk -v r="$newref" -v d="$gac" 'index($0, "REF=") == 1 { $0 = "REF=" r } index($0, "DIGEST=") == 1 { $0 = "DIGEST=" d } { print }' \
  "$PINFILE" > "$NEW" || fail "could not write $NEW"
mv "$NEW" "$PINFILE" || fail "could not write components/jdk/version"
echo "components/jdk/version: REF=$newref DIGEST=$gac, from $ga"
