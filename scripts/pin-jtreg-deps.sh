#!/bin/sh
# platform: host-agnostic
#   usage: sh scripts/pin-jtreg-deps.sh [--check]
#          Writes components/jtreg/deps: every file the pinned jtreg's make/build.sh downloads (Ant, the JT
#          Harness and AsmTools sources, JUnit, TestNG and its license, JCommander, Guice), as
#            <path under jtreg's build/deps> <SHA-256> <URL> [<fallback URL>...]
#          after TAG=<components/jtreg/version's TAG>. The versions and URLs come from that jtreg's own
#          make/build-support/version-numbers, by build.sh's own formulas, and each file must match the
#          SHA-1 jtreg pins for it there before its SHA-256 is written: jtreg pins SHA-1 only, and
#          build/toolchain.sh's jdk_jtreg prefetches by SHA-256, trying the URLs in order. Every URL that
#          answers must serve the same bytes; at least one must. Run it whenever the jtreg pin moves.
#          --check writes nothing, and exits 3 when the file is not what it would write.
#          Exits 0 written or current, 3 --check found it stale, 1 any failure, 2 usage.
# spec: tests/jtreg-deps-test.sh
set -eu
CHECK=0
case "$#:${1:-}" in
  0:) ;;
  1:--check) CHECK=1 ;;
  *) echo "usage: sh scripts/pin-jtreg-deps.sh [--check]" >&2; exit 2 ;;
esac
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/components/jtreg/deps"
fail() { echo "pin-jtreg-deps: $*" >&2; exit 1; }
. "$HERE/build/msc.sh"
. "$SHIPYARD/mavericks_fetch.sh"
tag="$(sed -n 's/^TAG=//p' "$HERE/components/jtreg/version" | tr -d ' \t\r')"
sha="$(sed -n 's/^SHA256=//p' "$HERE/components/jtreg/version" | tr -d ' \t\r')"
[ -n "$tag" ] && [ -n "$sha" ] || fail "components/jtreg/version needs TAG and SHA256"
T="$(mktemp -d "${TMPDIR:-/tmp}/pin-jtreg-deps.XXXXXX")"
trap 'rm -rf "$T"' EXIT
shipyard_fetch_pinned "https://github.com/openjdk/jtreg/archive/refs/tags/$tag.tar.gz" "$sha" "$T" "$tag.tar.gz" >&2 \
  || fail "could not fetch $tag"
vn="$T/jtreg-$(printf '%s' "$tag" | tr + -)/make/build-support/version-numbers"
[ -f "$vn" ] || fail "$tag has no make/build-support/version-numbers"
v() { _v="$(sed -n "s/^DEFAULT_$1=//p" "$vn" | tr -d ' \t\r')"; [ -n "$_v" ] || fail "$tag's version-numbers has no DEFAULT_$1"; printf '%s' "$_v"; }
maven=https://repo1.maven.org/maven2; tools=https://git.openjdk.org
ant="$(v ANT_VERSION)"; jth="$(v JTHARNESS_SRC_TAG)"; asm="$(v ASMTOOLS_SRC_TAG)"; ju="$(v JUNIT_VERSION)"
tng="$(v TESTNG_VERSION)"; tngl="$(v TESTNG_LICENSE_VERSION)"; jc="$(v JCOMMANDER_VERSION)"; gu="$(v GOOGLE_GUICE_VERSION)"
# platform: build.sh's own URL formulas (make/build.sh, make/build-support/build-common.sh and its asmtools
#           and jtharness build.sh) and the build/deps paths it downloads to
{
  # platform: archive.apache.org keeps every Ant release but GitHub's runners reach it only now and then;
  #           Apache's own mirrors (dlcdn, downloads) keep only the current release and Maven Central has no
  #           binary zip, and Huawei Cloud's Apache mirror keeps the old ones, byte for byte
  echo "apache-ant-$ant-bin.zip $(v ANT_ARCHIVE_CHECKSUM) https://archive.apache.org/dist/ant/binaries/apache-ant-$ant-bin.zip https://repo.huaweicloud.com/apache/ant/binaries/apache-ant-$ant-bin.zip"
  echo "jtharness/source.zip $(v JTHARNESS_SRC_ARCHIVE_CHECKSUM) $tools/jtharness/archive/$jth.zip"
  echo "asmtools/source.zip $(v ASMTOOLS_SRC_ARCHIVE_CHECKSUM) $tools/asmtools/archive/$asm.zip"
  echo "junit/junit-platform-console-standalone-$ju.jar $(v JUNIT_JAR_CHECKSUM) $maven/org/junit/platform/junit-platform-console-standalone/$ju/junit-platform-console-standalone-$ju.jar"
  echo "testng/testng-$tng.jar $(v TESTNG_JAR_CHECKSUM) $maven/org/testng/testng/$tng/testng-$tng.jar"
  echo "testng-license/LICENSE.txt $(v TESTNG_LICENSE_CHECKSUM) https://raw.githubusercontent.com/cbeust/testng/$tngl/LICENSE.txt"
  echo "jcommander/jcommander-$jc.jar $(v JCOMMANDER_JAR_CHECKSUM) $maven/com/beust/jcommander/$jc/jcommander-$jc.jar"
  echo "guice/guice-$gu.jar $(v GOOGLE_GUICE_JAR_CHECKSUM) $maven/com/google/inject/guice/$gu/guice-$gu.jar"
} > "$T/want"
{
  echo "TAG=$tag"
  while read -r p s1 urls; do
    s256=""
    for u in $urls; do
      rm -f "$T/f"
      SHIPYARD_FETCH_TRIES=2 shipyard_curl "$u" "$T/f" || { echo "pin-jtreg-deps: $u did not answer; checking the others" >&2; continue; }
      got1="$(shasum -a 1 < "$T/f" | cut -c1-40)"
      [ "$got1" = "$s1" ] || fail "$u is SHA-1 $got1, but $tag pins $s1"
      got256="$(shasum -a 256 < "$T/f" | cut -c1-64)"
      [ -z "$s256" ] || [ "$got256" = "$s256" ] || fail "$u serves other bytes than the URL before it"
      s256="$got256"
    done
    [ -n "$s256" ] || fail "no URL for $p answered: $urls"
    echo "$p $s256 $urls"
  done < "$T/want"
} > "$T/deps"
if [ "$CHECK" = 1 ]; then
  cmp -s "$T/deps" "$OUT" && exit 0
  echo "pin-jtreg-deps: components/jtreg/deps is not what $tag needs -- run sh scripts/pin-jtreg-deps.sh" >&2
  exit 3
fi
if cmp -s "$T/deps" "$OUT"; then echo "components/jtreg/deps: unchanged"; exit 0; fi
cp "$T/deps" "$OUT.new.$$" && mv "$OUT.new.$$" "$OUT" || fail "could not write $OUT"
echo "components/jtreg/deps: written for $tag"
