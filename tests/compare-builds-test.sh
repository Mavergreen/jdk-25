#!/bin/sh
# platform: macOS-only -- compiles its fixtures' Mach-O with build/toolchain.sh's clang22, and the compat guard reads them
# usage: sh tests/compare-builds-test.sh
#   build/compare-builds.sh CROSS_IMAGE NATIVE_IMAGE against fixture images, each a JDK home (bin, lib, conf,
#   man, release and one jmod holding a class, a man page and a dylib) with its build-info.txt beside it,
#   as build/build-jdk.sh and CI's image artifact leave them. Against the cross fixture:
#     a native image that agrees, its dylibs' bytes differing, its host and boot JDK differing, and with
#       pandoc=none and no man pages (PORT.md ruling R55): exit 0, naming each differing Mach-O and what
#       was excused;
#     one missing a file, one whose jmod is missing an entry: exit 1, naming it;
#     one with a different recaulk=: exit 1, naming the key and both values;
#     one whose dylib imports _clock_gettime: exit 1, naming the compat guard;
#     one with no man pages though its pandoc is the cross build's: exit 1;
#     one argument, or a directory with no build-info.txt beside it: exit 2.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
fail() { echo "FAIL $*"; exit 1; }
[ "$(uname -s)" = Darwin ] || { echo "SKIP: compare-builds needs macOS"; exit 77; }
. "$MAVERICKS_ROOT/build/toolchain.sh"
jdk_toolchain > /dev/null 2>&1 || fail "jdk_toolchain failed"
t="$(mktemp -d "${TMPDIR:-/tmp}/compare-builds-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT

dylib() {
  printf 'int jdk_fixture(void) { return %s; }\n%s\n' "$2" "${3:-}" > "$t/src.c"
  $CC -mmacosx-version-min=10.9 -dynamiclib -Wl,-undefined,dynamic_lookup -o "$1" "$t/src.c" \
    || fail "fixture: could not compile $1"
}
image() {
  i="$1/image"
  mkdir -p "$i/bin" "$i/lib" "$i/conf" "$i/man/man1" "$i/jmods" "$t/jm"
  dylib "$i/lib/libfixture.dylib" "$2"
  printf 'JAVA_VERSION="25.0.5.0.3"\n' > "$i/release"
  printf 'networkaddress.cache.ttl=30\n' > "$i/conf/net.properties"
  printf '.TH JAVA 1\n' > "$i/man/man1/java.1"
  rm -rf "$t/jm"; mkdir -p "$t/jm/classes" "$t/jm/lib" "$t/jm/man/man1"
  printf 'CAFEBABE\n' > "$t/jm/classes/module-info.class"
  printf '.TH JAVA 1\n' > "$t/jm/man/man1/java.1"
  dylib "$t/jm/lib/libfixture.dylib" "$2"
  rm -f "$t/jm.zip"; (cd "$t/jm" && zip -qr "$t/jm.zip" .) || fail "fixture: zip failed"
  # platform: a jmod is a zip behind the 4-byte header "JM" 1 0
  printf 'JM\001\000' > "$i/jmods/java.base.jmod"; cat "$t/jm.zip" >> "$i/jmods/java.base.jmod"
}
info() {
  d="$1"; shift
  printf '%s\n' bootjdk=jdk-25.0.5+8 clang22=22.1.8-mavericks.12 host=arm64-macos26.1 pandoc=3.13 \
    recaulk=20261025.5 upstream=25.0.5.0.3 > "$d/build-info.txt"
  for kv in "$@"; do
    grep -v "^${kv%%=*}=" "$d/build-info.txt" > "$t/bi"; printf '%s\n' "$kv" >> "$t/bi"
    sort "$t/bi" > "$d/build-info.txt"
  done
}
nojmodman() {
  rm -rf "$t/jm" "$t/jm.zip"; mkdir -p "$t/jm"
  (cd "$t/jm" && unzip -qo "$1/image/jmods/java.base.jmod" 2>/dev/null) || :
  rm -rf "$t/jm/man"; (cd "$t/jm" && zip -qr "$t/jm.zip" .) || fail "fixture: zip failed"
  printf 'JM\001\000' > "$1/image/jmods/java.base.jmod"; cat "$t/jm.zip" >> "$1/image/jmods/java.base.jmod"
}
run() { rc=0; sh "$MAVERICKS_ROOT/build/compare-builds.sh" "$@" > "$t/out" 2>&1 || rc=$?; }
has() { grep -q "$1" "$t/out" || fail "$2: the output does not say '$1': $(cat "$t/out")"; }

c="$t/cross"; image "$c" 1; info "$c"

n="$t/agree"; image "$n" 2; info "$n" host=x86_64-macos10.9.5 bootjdk=jdk25-25.0.5.0.3+3-mavericks.1 pandoc=none
rm -rf "$n/image/man"; nojmodman "$n"
run "$c/image" "$n/image"
[ "$rc" = 0 ] || fail "an agreeing native image: exit $rc, not 0: $(cat "$t/out")"
has 'Mach-O differs: lib/libfixture.dylib' "an agreeing native image"
has 'Mach-O differs: jmods/java.base.jmod!lib/libfixture.dylib' "an agreeing native image"
has 'excused: host' "an agreeing native image"
has 'excused: bootjdk' "an agreeing native image"
has 'excused (pandoc=none): man/man1/java.1' "an agreeing native image"

n="$t/missing"; image "$n" 1; info "$n"; rm "$n/image/conf/net.properties"
run "$c/image" "$n/image"
[ "$rc" = 1 ] || fail "a native image missing a file: exit $rc, not 1: $(cat "$t/out")"
has 'only in cross: conf/net.properties' "a native image missing a file"

n="$t/jmodmissing"; image "$n" 1; info "$n"; nojmodman "$n"
run "$c/image" "$n/image"
[ "$rc" = 1 ] || fail "a native jmod missing its man page, pandoc the same: exit $rc, not 1: $(cat "$t/out")"
has 'only in cross: jmods/java.base.jmod!man/man1/java.1' "a native jmod missing an entry"

n="$t/recaulk"; image "$n" 1; info "$n" recaulk=20261101.1
run "$c/image" "$n/image"
[ "$rc" = 1 ] || fail "a native image with another recaulk: exit $rc, not 1: $(cat "$t/out")"
has 'build-info: recaulk differs: 20261025.5 (cross) vs 20261101.1 (native)' "a native image with another recaulk"

n="$t/guard"; image "$n" 1; info "$n"
dylib "$n/image/lib/libfixture.dylib" 1 'int clock_gettime(int, void *); int jdk_late(void) { return clock_gettime(0, 0); }'
run "$c/image" "$n/image"
[ "$rc" = 1 ] || fail "a native image importing _clock_gettime: exit $rc, not 1: $(cat "$t/out")"
has 'compat guard refuses native' "a native image importing _clock_gettime"

n="$t/noman"; image "$n" 1; info "$n"; rm -rf "$n/image/man"
run "$c/image" "$n/image"
[ "$rc" = 1 ] || fail "a native image without man pages, pandoc the same: exit $rc, not 1: $(cat "$t/out")"
has 'only in cross: man/man1/java.1' "a native image without man pages, pandoc the same"

run "$c/image"
[ "$rc" = 2 ] || fail "one argument: exit $rc, not 2"
mkdir -p "$t/bare/image"
run "$c/image" "$t/bare/image"
[ "$rc" = 2 ] || fail "an image with no build-info.txt beside it: exit $rc, not 2: $(cat "$t/out")"
echo "PASS: compare-builds"
