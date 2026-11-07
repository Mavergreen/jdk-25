#!/bin/sh
# platform: host-agnostic
#   usage: sh scripts/pin-source-tarballs.sh [--check]
#          Writes into components/jdk/version the SHA-256 of GitHub's tarball of the pinned JDK commit
#          (DIGEST), as TARBALL_SHA256, by which build/fetch-jdk.sh verifies the source it fetches.
#          Renovate moves REF and DIGEST but cannot compute a hash: run this on a JDK bump's branch and
#          commit the file. A hash is written only for a tarball that holds exactly its commit's files:
#          the commit is fetched with shipyard's clone_pinned.sh and compared, by git, with the extracted
#          tarball (so this runs where git is; the builds never run it). --check writes nothing, and
#          fails naming the pin when it is not its tarball's SHA-256. The file is written once, after the
#          row is verified, by a rename from beside it: a failure or a signal anywhere leaves it as it
#          was, with no temp file behind.
#          Exits (the pins bot relies on them): 0 the pin is current (or was just written); 3 --check
#          found a pin that is not its tarball's; 1 any failure (a tarball not its commit's tree, a
#          failed fetch, a refused digest, a missing pin line, a failed command); 2 usage, and only
#          usage; 130/143 on INT/TERM.
#          Needs curl, git, tar, shasum and shipyard (msc.sh).
set -eu
CHECK=0
case "$#:${1:-}" in
  0:) ;;
  1:--check) CHECK=1 ;;
  *) echo "usage: sh scripts/pin-source-tarballs.sh [--check]" >&2; exit 2 ;;
esac
T=""; NEW=""; want=""
trap 'rc=$?; [ -z "$T" ] || rm -rf "$T"; [ -z "$NEW" ] || rm -f "$NEW"; [ "$rc" = "$want" ] || rc=1; exit "$rc"' EXIT
trap 'want=130; exit 130' INT
trap 'want=143; exit 143' TERM
finish() { want=$1; exit "$1"; }
fail() { echo "FAIL: $*" >&2; finish 1; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PINFILE="$HERE/components/jdk/version"
. "$PINFILE"
. "$HERE/build/msc.sh"    # -> $SHIPYARD (fetch_pinned_source.sh --url, clone_pinned.sh, mavericks_fetch.sh's shipyard_curl)
[ -f "$SHIPYARD/fetch_pinned_source.sh" ] || fail "the shipyard at $SHIPYARD has no fetch_pinned_source.sh -- install a newer shipyard pkg"
[ -f "$SHIPYARD/mavericks_fetch.sh" ] || fail "the shipyard at $SHIPYARD has no mavericks_fetch.sh"
. "$SHIPYARD/mavericks_fetch.sh"
grep -q '^TARBALL_SHA256=[0-9a-f]*$' "$PINFILE" || fail "components/jdk/version has no TARBALL_SHA256=... line"
T="$(mktemp -d "${TMPDIR:-/tmp}/pin-source-tarballs.XXXXXX")"
NEW="$PINFILE.new.$$"   # beside the pin file, so the one write is a rename within a file system
pin=TARBALL_SHA256; repo=$REPO; commit=$DIGEST; tag=$REF
url="$(sh "$SHIPYARD/fetch_pinned_source.sh" --url "$repo" "$commit")" || fail "shipyard has no tarball URL for $repo at '$commit'"
echo "==> $pin: $url"
shipyard_curl "$url" "$T/src.tar.gz" || fail "could not fetch $url"
sha="$(shasum -a 256 < "$T/src.tar.gz" | cut -c1-64)"
mkdir -p "$T/x" && tar xzf "$T/src.tar.gz" -C "$T/x" || fail "could not extract $url"
top="$(ls -A "$T/x")"
[ -d "$T/x/$top" ] && [ "$(printf '%s\n' "$top" | wc -l | tr -d ' ')" = 1 ] || fail "$url holds more than one directory: $top"
tree="$T/x/$top"
# platform: git status never looks at an entry named .git (a directory, or a gitdir file) and
#           never reports an empty directory, so a tarball could carry either unseen. Neither is in
#           a commit's tree: git tracks no directory, and jdk25u has no submodule (whose gitlink git
#           archive writes as an empty directory).
extra="$(find "$tree" \( -name .git -o -type d -empty \) -print | head -5)"
[ -z "$extra" ] || { printf '%s\n' "$extra" >&2; fail "$url is not commit $commit's tree: it holds the .git or empty directory above"; }
sh "$SHIPYARD/clone_pinned.sh" "$repo" "$tag" "$commit" "$T/clone" || fail "could not clone $repo at $commit"
# platform: the flags make the comparison the same on every host: a macOS clone's own
#           core.ignorecase=true would pass a name that differs only in case, and fileMode, symlinks and
#           autocrlf are set rather than left to the host's git.
diffs="$(git -c core.precomposeunicode=false -c core.ignorecase=false -c core.autocrlf=false -c core.fileMode=true \
  -c core.symlinks=true --git-dir="$T/clone/.git" --work-tree="$tree" status --porcelain --untracked-files=all --ignored)" \
  || fail "git could not compare $url with commit $commit"
[ -z "$diffs" ] || { printf '%s\n' "$diffs" | head -20 >&2; fail "$url is not commit $commit's tree (the differences above)"; }
echo "    $sha (the commit's tree, file for file)"
if [ "$CHECK" = 1 ]; then
  [ "$TARBALL_SHA256" = "$sha" ] || { echo "FAIL: components/jdk/version's $pin is $TARBALL_SHA256, but $url is $sha -- run sh scripts/pin-source-tarballs.sh and commit it" >&2; finish 3; }
  finish 0
fi
if [ "$TARBALL_SHA256" = "$sha" ]; then echo "components/jdk/version: unchanged"; finish 0; fi
awk -v v="$sha" 'index($0, "TARBALL_SHA256=") == 1 { $0 = "TARBALL_SHA256=" v } { print }' "$PINFILE" > "$T/next" \
  && grep -q "^TARBALL_SHA256=$sha\$" "$T/next" || fail "could not write $pin"
cp "$T/next" "$NEW" && mv "$NEW" "$PINFILE" || fail "could not write components/jdk/version"
echo "components/jdk/version: wrote the moved pin"
finish 0
