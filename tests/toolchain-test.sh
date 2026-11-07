#!/bin/sh
# platform: macOS-only -- jdk_toolchain needs the pkgs clang22 and Recaulk ship as
# usage: sh tests/toolchain-test.sh
#   The toolchain half of build/toolchain.sh and the shape of every pin it reads. Runs on every
#   Mac; exits 77 (skip) elsewhere. The boot JDK is tests/boot-jdk-test.sh, apart, so that its skip
#   on a host that cannot run the pinned JDK never hides these.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
fail() { echo "FAIL $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || { echo "SKIP: toolchain needs macOS to expand pkgs"; exit 77; }

. "$MAVERICKS_ROOT/build/toolchain.sh"

case "$(jdk_pin clang22)" in *-mavericks.[0-9]*) ;; *) fail "clang22 pin '$(jdk_pin clang22)' is not X.Y.Z-mavericks.N" ;; esac
case "$(jdk_pin recaulk)" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9]*) ;; *) fail "recaulk pin is not YYYYMMDD.N" ;; esac
case "$(jdk_pin longboat)" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9]*) ;; *) fail "longboat pin is not YYYYMMDD.N" ;; esac
b="$MAVERICKS_ROOT/components/bootjdk/version"
grep -Eq '^TAG=jdk-25\.[0-9]+\.[0-9]+(\.[0-9]+)?\+[0-9]+$' "$b" || fail "bootjdk TAG is not a jdk-25.* GA tag"
grep -Eq '^SHA256=[0-9a-f]{64}$' "$b" || fail "bootjdk SHA256 is not 64 hex"
j="$MAVERICKS_ROOT/components/jtreg/version"
grep -Eq '^TAG=jtreg-[0-9]+(\.[0-9]+)*\+[0-9]+$' "$j" || fail "jtreg TAG is not jtreg-<version>+<build>, as jtreg-8+2 or jtreg-7.5.2+1"
grep -Eq '^SHA256=[0-9a-f]{64}$' "$j" || fail "jtreg SHA256 is not 64 hex"

[ "$(MAVERICKS_BUILD_ROOT=/x jdk_build_root)" = /x/jdk-25 ] || fail "jdk_build_root ignores MAVERICKS_BUILD_ROOT"

# spec: SKILL.md "Family conventions" check 28 -- no unpinned fetch
if grep -q 'releases/latest' "$MAVERICKS_ROOT/build/toolchain.sh"; then fail "toolchain.sh fetches releases/latest"; fi

r="$MAVERICKS_ROOT/.github/renovate.json"
grep -q 'components/clang22/version' "$r" || fail "renovate.json has no clang22 manager"
grep -q 'components/longboat/version' "$r" || fail "renovate.json has no longboat manager"
grep -q 'components/bootjdk/version' "$r" || fail "renovate.json has no bootjdk manager"
grep -q 'temurin25-binaries' "$r" || fail "bootjdk manager does not track temurin25-binaries"
grep -q 'github-release-attachments' "$r" || fail "bootjdk manager is not github-release-attachments"
grep -q '<26' "$r" || fail "bootjdk is not capped <26"
grep -q 'components/jtreg/version' "$r" || fail "renovate.json has no jtreg manager"
if grep -q 'components/recaulk' "$r"; then fail "recaulk has a local manager; shipyard's preset tracks it"; fi
i="$MAVERICKS_ROOT/INGREDIENTS.md"
for l in 'bootjdk: components/bootjdk/version' 'clang22: components/clang22/version' 'recaulk: components/recaulk/version'; do
  grep -q "^- $l\$" "$i" || fail "INGREDIENTS.md Declared state lacks '- $l'"
done
if grep -q '^- longboat' "$i"; then fail "longboat is in Declared state"; fi
for n in bootjdk clang22 recaulk longboat jtreg; do grep -q "components/$n/version" "$i" || fail "INGREDIENTS.md has no row for $n"; done

jdk_toolchain x86_64 2>/dev/null || jdk_toolchain || fail "jdk_toolchain failed"
[ "$MACOSX_DEPLOYMENT_TARGET" = 10.9 ] || fail "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
case "$SDKROOT" in *MacOSX10.9.sdk) ;; *) fail "SDKROOT=$SDKROOT" ;; esac
# shellcheck disable=SC2086
$CC --version >/dev/null 2>&1 || fail "'$CC --version' does not run"
[ -x "$CLANG22_BIN/clang" ] || fail "no clang in CLANG22_BIN=$CLANG22_BIN"
[ -f "$RECAULK_LIB" ] || fail "RECAULK_LIB=$RECAULK_LIB missing"
[ -d "$RECAULK_INCLUDE" ] || fail "RECAULK_INCLUDE=$RECAULK_INCLUDE missing"
for v in CXX AR NM; do eval "[ -n \"\${$v:-}\" ]" || fail "$v unset"; done
echo "PASS: toolchain"
