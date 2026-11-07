#!/bin/sh
# platform: macOS-only -- builds the pinned jtreg with build/toolchain.sh's boot JDK
# usage: sh tests/jtreg-deps-test.sh
#   jtreg's make/build.sh downloads its own dependencies with wget or curl, unpinned and without retry
#   (archive.apache.org's Ant failed CI twice). build/toolchain.sh's jdk_jtreg_fetch fetches the jtreg
#   source and every file components/jtreg/deps pins, each verified by SHA-256, into caches under the
#   build root; jdk_jtreg then builds jtreg without fetching anything. With those caches warm, jdk_jtreg
#   runs in a fresh build root with wget and curl shadowed on PATH by stubs that record each call and
#   fail: the build must succeed, with no call recorded and no download line in its output.
#   A deps file made for another jtreg TAG must be refused before anything is fetched, and a file whose
#   first URL does not answer must be fetched from the next one.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
fail() { echo "FAIL $*"; exit 1; }
case "$(uname -s)" in Darwin) ;; *) echo "SKIP jtreg-deps: macOS only"; exit 77 ;; esac
. "$MAVERICKS_ROOT/build/toolchain.sh"
boot="$(jdk_boot_jdk)" || fail "jdk_boot_jdk failed"
mkdir -p "$(jdk_build_root)"
t="$(mktemp -d "$(jdk_build_root)/jtreg-deps-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT
MAVERICKS_BUILD_ROOT="$t/root"; export MAVERICKS_BUILD_ROOT
jdk_jtreg_fetch > "$t/fetch.out" 2>&1 || fail "jdk_jtreg_fetch failed: $(tail -5 "$t/fetch.out")"

mkdir -p "$t/stub"
for c in wget curl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/net.log"\nexit 1\n' "$c" "$t" > "$t/stub/$c"; chmod +x "$t/stub/$c"
done
home="$(PATH="$t/stub:$PATH" jdk_jtreg "$boot" 2> "$t/build.err")" || fail "jdk_jtreg failed with the network shadowed: $(tail -15 "$t/build.err")"
[ ! -s "$t/net.log" ] || fail "jdk_jtreg ran wget or curl after jdk_jtreg_fetch: $(cat "$t/net.log")"
if grep -q 'Downloading ' "$t/build.err"; then fail "jtreg's build.sh downloaded: $(grep 'Downloading ' "$t/build.err")"; fi
[ -x "$home/bin/jtreg" ] || fail "jdk_jtreg printed $home, which has no bin/jtreg"
JAVA_HOME="$boot" "$home/bin/jtreg" -version > "$t/v" 2>&1 || fail "the built jtreg does not run: $(cat "$t/v")"
want="$(sed -n 's/^TAG=jtreg-//p' "$MAVERICKS_ROOT/components/jtreg/version")"
grep -q "^jtreg $want\$" "$t/v" || fail "the built jtreg is not $want: $(cat "$t/v")"

mkdir -p "$t/other/components/jtreg" "$t/other/build"
cp "$MAVERICKS_ROOT/components/jtreg/version" "$t/other/components/jtreg/version"
sed 's/^TAG=.*/TAG=jtreg-0+0/' "$MAVERICKS_ROOT/components/jtreg/deps" > "$t/other/components/jtreg/deps"
MAVERICKS_BUILD_ROOT="$t/root2"
if (MAVERICKS_ROOT="$t/other"; jdk_jtreg_fetch) > "$t/o" 2>&1; then fail "a deps file made for jtreg-0+0 was taken for $want"; fi
grep -q "components/jtreg/deps is for jtreg-0+0" "$t/o" || fail "the stale deps file's refusal does not name it: $(cat "$t/o")"
[ ! -e "$t/root2/jdk-25/jtreg-deps" ] || fail "a stale deps file was refused only after fetching"
mkdir -p "$t/fb/components/jtreg" "$t/fb/build"
cp "$MAVERICKS_ROOT/components/jtreg/version" "$t/fb/components/jtreg/version"
awk '$1 == "testng-license/LICENSE.txt" { $3 = "http://127.0.0.1:9/LICENSE.txt " $3 } { print }' \
  "$MAVERICKS_ROOT/components/jtreg/deps" > "$t/fb/components/jtreg/deps"
grep -q '127.0.0.1:9' "$t/fb/components/jtreg/deps" || fail "fixture: no dead first URL written"
MAVERICKS_BUILD_ROOT="$t/root3"
(MAVERICKS_ROOT="$t/fb"; jdk_jtreg_fetch) > "$t/o" 2>&1 || fail "a dead first URL was not passed over for the next: $(tail -5 "$t/o")"
lic="$(awk '$1 == "testng-license/LICENSE.txt" { print $2 }' "$MAVERICKS_ROOT/components/jtreg/deps")"
[ -s "$t/root3/jdk-25/jtreg-deps/$lic" ] || fail "the license was not fetched from its second URL"
echo "PASS: jtreg-deps (jtreg $want built with wget and curl shadowed: no download)"
