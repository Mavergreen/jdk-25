#!/bin/sh
# platform: host-agnostic
#   usage: sh scripts/pin-jtreg.sh [--check]
#          Moves components/jtreg/version to the jtreg the pinned jdk source's own CI runs (ruling R48):
#          JTREG_VERSION in make/conf/github-actions.conf at components/jdk/version's DIGEST. When TAG is
#          already jtreg-<that version>, it is current: nothing is fetched or written. Otherwise it writes
#          TAG=jtreg-<version> and SHA256, the SHA-256 of GitHub's tarball of that tag, as
#          scripts/pin-source-tarballs.sh does for the jdk: the tag's commit is found with git ls-remote,
#          cloned with shipyard's clone_pinned.sh and compared, by git, with the extracted tarball, and
#          only a tarball that holds exactly that commit's files is hashed. The file is written once, by
#          a rename from beside it. components/jtreg/deps is scripts/pin-jtreg-deps.sh's: run it after a
#          write. --check writes nothing, and exits 3 naming both when TAG is another jtreg.
#          Exits (the pins bot relies on them): 0 current (or just written); 3 --check found another
#          jtreg; 1 any failure (a JTREG_VERSION that is missing or not N[.N...]+N, a tag jtreg lacks, a
#          tarball not its tag's tree, a failed fetch or command); 2 usage, and only usage.
#          PIN_JTREG_RAW, PIN_JTREG_GITHUB and PIN_JTREG_REPO replace https://raw.githubusercontent.com,
#          https://github.com and https://github.com/openjdk/jtreg (the tests). Needs curl, git, tar,
#          shasum and shipyard (msc.sh).
# spec: tests/pin-jtreg-test.sh
set -eu
CHECK=0
case "$#:${1:-}" in
  0:) ;;
  1:--check) CHECK=1 ;;
  *) echo "usage: sh scripts/pin-jtreg.sh [--check]" >&2; exit 2 ;;
esac
T=""; NEW=""; want=""
trap 'rc=$?; [ -z "$T" ] || rm -rf "$T"; [ -z "$NEW" ] || rm -f "$NEW"; [ "$rc" = "$want" ] || rc=1; exit "$rc"' EXIT
trap 'want=130; exit 130' INT
trap 'want=143; exit 143' TERM
finish() { want=$1; exit "$1"; }
fail() { echo "pin-jtreg: $*" >&2; finish 1; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PINFILE="$HERE/components/jtreg/version"
raw="${PIN_JTREG_RAW:-https://raw.githubusercontent.com}"
gh="${PIN_JTREG_GITHUB:-https://github.com}"
jrepo="${PIN_JTREG_REPO:-https://github.com/openjdk/jtreg}"
. "$HERE/build/msc.sh"
[ -f "$SHIPYARD/mavericks_fetch.sh" ] || fail "the shipyard at $SHIPYARD has no mavericks_fetch.sh"
. "$SHIPYARD/mavericks_fetch.sh"
pin="$(sed -n 's/^TAG=//p' "$PINFILE")"
case "$pin" in jtreg-?*) : ;; *) fail "components/jtreg/version has no TAG=jtreg-<version>" ;; esac
grep -q '^SHA256=' "$PINFILE" || fail "components/jtreg/version has no SHA256 line"
repo="$(sed -n 's/^REPO=//p' "$HERE/components/jdk/version")"
digest="$(sed -n 's/^DIGEST=//p' "$HERE/components/jdk/version")"
case "$repo" in https://github.com/*/*) : ;; *) fail "components/jdk/version's REPO '$repo' is not a GitHub repository" ;; esac
case "$digest" in *[!0-9a-f]*|'') fail "components/jdk/version's DIGEST '$digest' is not a commit" ;; esac
[ "${#digest}" -eq 40 ] || fail "components/jdk/version's DIGEST '$digest' is not a commit"
T="$(mktemp -d "${TMPDIR:-/tmp}/pin-jtreg.XXXXXX")"
curl_url="$raw/${repo#https://github.com/}/$digest/make/conf/github-actions.conf"
shipyard_curl "$curl_url" "$T/conf" || fail "could not fetch $curl_url"
ver="$(sed -n 's/^JTREG_VERSION=//p' "$T/conf" | tr -d ' \t\r')"
[ -n "$ver" ] || fail "make/conf/github-actions.conf at $digest names no JTREG_VERSION"
printf '%s\n' "$ver" | grep -xE '[0-9]+(\.[0-9]+)*\+[0-9]+' > /dev/null \
  || fail "make/conf/github-actions.conf at $digest names JTREG_VERSION '$ver', which is not N[.N...]+N"
tag="jtreg-$ver"
if [ "$pin" = "$tag" ]; then echo "pin-jtreg: $pin, as the jdk source's own CI runs"; finish 0; fi
if [ "$CHECK" = 1 ]; then
  echo "pin-jtreg: components/jtreg/version pins $pin, but the jdk source's own CI runs $tag -- run sh scripts/pin-jtreg.sh" >&2
  finish 3
fi
refs="$(git ls-remote "$jrepo" "refs/tags/$tag" "refs/tags/$tag^{}")" || fail "git ls-remote $jrepo failed"
commit="$(printf '%s\n' "$refs" | awk -v t="refs/tags/$tag^{}" '$2 == t { print $1 }')"
[ -n "$commit" ] || commit="$(printf '%s\n' "$refs" | awk -v t="refs/tags/$tag" '$2 == t { print $1 }')"
case "$commit" in *[!0-9a-f]*|'') fail "$jrepo has no tag $tag" ;; esac
url="$gh/openjdk/jtreg/archive/refs/tags/$tag.tar.gz"
echo "==> $tag: $url"
shipyard_curl "$url" "$T/src.tar.gz" || fail "could not fetch $url"
sha="$(shasum -a 256 < "$T/src.tar.gz" | cut -c1-64)"
mkdir -p "$T/x" && tar xzf "$T/src.tar.gz" -C "$T/x" || fail "could not extract $url"
top="$(ls -A "$T/x")"
[ -d "$T/x/$top" ] && [ "$(printf '%s\n' "$top" | wc -l | tr -d ' ')" = 1 ] || fail "$url holds more than one directory: $top"
tree="$T/x/$top"
# platform: as in scripts/pin-source-tarballs.sh: git status never looks at a .git or reports an empty
#           directory, and neither is in a commit's tree
extra="$(find "$tree" \( -name .git -o -type d -empty \) -print | head -5)"
[ -z "$extra" ] || { printf '%s\n' "$extra" >&2; fail "$url is not $tag's tree: it holds the .git or empty directory above"; }
sh "$SHIPYARD/clone_pinned.sh" "$jrepo" "$tag" "$commit" "$T/clone" || fail "could not clone $jrepo at $commit"
diffs="$(git -c core.precomposeunicode=false -c core.ignorecase=false -c core.autocrlf=false -c core.fileMode=true \
  -c core.symlinks=true --git-dir="$T/clone/.git" --work-tree="$tree" status --porcelain --untracked-files=all --ignored)" \
  || fail "git could not compare $url with $tag"
[ -z "$diffs" ] || { printf '%s\n' "$diffs" | head -20 >&2; fail "$url is not $tag's tree (the differences above)"; }
echo "    $sha ($tag's tree, file for file)"
NEW="$PINFILE.new.$$"
awk -v t="$tag" -v s="$sha" 'index($0, "TAG=") == 1 { $0 = "TAG=" t } index($0, "SHA256=") == 1 { $0 = "SHA256=" s } { print }' \
  "$PINFILE" > "$T/next" && grep -qxF "TAG=$tag" "$T/next" && grep -qx "SHA256=$sha" "$T/next" || fail "could not write the pin"
cp "$T/next" "$NEW" && mv "$NEW" "$PINFILE" || fail "could not write components/jtreg/version"
NEW=""
echo "components/jtreg/version: $tag; run sh scripts/pin-jtreg-deps.sh for its build dependencies"
finish 0
