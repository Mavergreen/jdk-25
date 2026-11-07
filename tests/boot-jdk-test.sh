#!/bin/sh
# platform: host-agnostic
# usage: sh tests/boot-jdk-test.sh
#   jdk_boot_jdk prints a JDK home whose bin/java -version exits 0 and reports 25. The pinned boot
#   JDK is a Temurin aarch64 build, so it runs only on arm64 macOS 11+; and on Mac OS X 10.9 only
#   our own /usr/local/mavergreen/jdk25 can serve (it exists only once a release is installed). Exits
#   77 (skip) on any other host. Apart from tests/toolchain-test.sh so a skip here hides nothing there.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
fail() { echo "FAIL $*" >&2; exit 1; }
if [ ! -x /usr/local/mavergreen/jdk25/bin/java ]; then
  if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ] || [ "$(uname -r | cut -d. -f1)" -lt 20 ]; then
    echo "SKIP: the pinned boot JDK runs only on arm64 macOS 11+ (or with /usr/local/mavergreen/jdk25 installed)"; exit 77
  fi
fi
. "$MAVERICKS_ROOT/build/toolchain.sh"
home="$(jdk_boot_jdk)" || fail "jdk_boot_jdk failed"
[ -x "$home/bin/java" ] || fail "no $home/bin/java"
out="$("$home/bin/java" -version 2>&1)" || fail "java -version exits non-zero: $out"
printf '%s\n' "$out" | grep -Eq '(version "|openjdk )25' || fail "java -version does not report 25: $out"
echo "PASS: boot-jdk ($home)"
