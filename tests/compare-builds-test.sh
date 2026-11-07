#!/bin/sh
# platform: macOS-only -- compiles its fixtures' Mach-O with build/toolchain.sh's clang22, and the compat guard reads them
# usage: sh tests/compare-builds-test.sh
#   build/compare-builds.sh CROSS_IMAGE NATIVE_IMAGE against fixture images, each a JDK home (bin, conf,
#   man, release, lib with a dylib, lib/modules and a jar with a manifest, and one jmod holding
#   module-info.class, a class, a man page, a dylib and lib/ct.sym, a zip) with its build-info.txt beside
#   it, as build/build-jdk.sh and CI's image artifact leave them. Every fixture's jar, jmod and ct.sym is
#   zipped with its own entry times. Against the cross fixture:
#     a native image that agrees, its dylibs' bytes differing and so lib/modules and the ModuleHashes in
#       module-info.class, its host and boot JDK differing and so its jar manifest's Created-By, and with
#       pandoc=none and no man pages (PORT.md ruling R55): exit 0, naming each differing Mach-O and what
#       was excused;
#     one whose conf/net.properties differs, one whose jmod's or jar's class differs, one whose lib/modules differs
#       while no Mach-O does, one whose module-info.class differs without ModuleHashes, one whose ct.sym
#       holds a different entry, one whose manifest's Created-By differs with the same boot JDK, one whose
#       manifest differs elsewhere than Created-By: exit 1, naming it;
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
  $CC -mmacosx-version-min=10.9 -dynamiclib -Wl,-undefined,dynamic_lookup -Wl,-install_name,@rpath/libfixture.dylib \
    -o "$1" "$t/src.c" \
    || fail "fixture: could not compile $1"
}
stamp=200001010000
zipped() {
  stamp=$((stamp + 1))
  find "$1" -exec touch -t "$stamp" {} + && rm -f "$t/z.zip" && (cd "$1" && zip -qrX "$t/z.zip" .) \
    || fail "fixture: zip failed"
}
jmod() {
  zipped "$t/jm"
  # platform: a jmod is a zip behind the 4-byte header "JM" 1 0
  printf 'JM\001\000' > "$1/image/jmods/java.base.jmod"; cat "$t/z.zip" >> "$1/image/jmods/java.base.jmod"
}
image() {
  i="$1/image"
  mkdir -p "$i/bin" "$i/lib" "$i/conf" "$i/man/man1" "$i/jmods"
  dylib "$i/lib/libfixture.dylib" "$2"
  printf 'jimage holding ModuleHashes of %s\n' "$2" > "$i/lib/modules"
  printf 'JAVA_VERSION="25.0.5.0.3"\n' > "$i/release"
  printf 'networkaddress.cache.ttl=30\n' > "$i/conf/net.properties"
  printf '.TH JAVA 1\n' > "$i/man/man1/java.1"
  rm -rf "$t/jm"; mkdir -p "$t/jm/jdk/internal/jrtfs" "$t/jm/META-INF"
  printf 'CAFEBABE jrtfs\n' > "$t/jm/jdk/internal/jrtfs/JrtFileSystem.class"
  printf 'Manifest-Version: 1.0\r\nCreated-By: %s\r\n%s\r\n' "${3:-25.0.5 (Eclipse Adoptium)}" "${5:-}" \
    > "$t/jm/META-INF/MANIFEST.MF"
  zipped "$t/jm"; cp "$t/z.zip" "$i/lib/jrt-fs.jar"
  rm -rf "$t/ct"; mkdir -p "$t/ct/9/java.base/java/lang"
  printf 'sig %s\n' "${4:-Object}" > "$t/ct/9/java.base/java/lang/Object.sig"
  zipped "$t/ct"
  rm -rf "$t/jm"; mkdir -p "$t/jm/classes" "$t/jm/lib" "$t/jm/man/man1"
  cp "$t/z.zip" "$t/jm/lib/ct.sym"
  printf 'CAFEBABE ModuleHashes %s\n' "$2" > "$t/jm/classes/module-info.class"
  printf 'CAFEBABE Object\n' > "$t/jm/classes/Object.class"
  printf '.TH JAVA 1\n' > "$t/jm/man/man1/java.1"
  dylib "$t/jm/lib/libfixture.dylib" "$2"
  jmod "$1"
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
unjmod() { rm -rf "$t/jm"; mkdir -p "$t/jm"; (cd "$t/jm" && unzip -qo "$1/image/jmods/java.base.jmod" 2>/dev/null) || :; }
nojmodman() { unjmod "$1"; rm -rf "$t/jm/man"; jmod "$1"; }
run() { rc=0; sh "$MAVERICKS_ROOT/build/compare-builds.sh" "$@" > "$t/out" 2>&1 || rc=$?; }
has() { grep -q "$1" "$t/out" || fail "$2: the output does not say '$1': $(cat "$t/out")"; }

c="$t/cross"; image "$c" 1; info "$c"

n="$t/agree"; image "$n" 2 '25.0.5.0.3 (Mavergreen)'
info "$n" host=x86_64-macos10.9.5 bootjdk=jdk25-25.0.5.0.3+3-mavericks.1 pandoc=none
rm -rf "$n/image/man"; nojmodman "$n"
run "$c/image" "$n/image"
[ "$rc" = 0 ] || fail "an agreeing native image: exit $rc, not 0: $(cat "$t/out")"
has 'Mach-O differs: lib/libfixture.dylib' "an agreeing native image"
has 'Mach-O differs: jmods/java.base.jmod!lib/libfixture.dylib' "an agreeing native image"
has 'excused: host' "an agreeing native image"
has 'excused: bootjdk' "an agreeing native image"
has 'excused (pandoc=none): man/man1/java.1' "an agreeing native image"
has 'excused (records Mach-O hashes): lib/modules' "an agreeing native image"
has 'excused (records Mach-O hashes): jmods/java.base.jmod!classes/module-info.class' "an agreeing native image"
has "excused (bootjdk's jar wrote it): lib/jrt-fs.jar!META-INF/MANIFEST.MF:Created-By" "an agreeing native image"
if grep -q 'jrt-fs.jar!jdk\|MANIFEST.MF$' "$t/out"; then fail "a jar whose entries agree was reported: $(cat "$t/out")"; fi
if grep -q 'ct.sym' "$t/out"; then fail "a ct.sym whose entries agree was reported: $(cat "$t/out")"; fi

n="$t/same"; image "$n" 1; info "$n"
run "$c/image" "$n/image"
[ "$rc" = 0 ] || fail "a native image with the cross image's bytes: exit $rc, not 0: $(cat "$t/out")"
if grep -q 'differs' "$t/out"; then fail "fixture: the same sources made different bytes: $(cat "$t/out")"; fi

n="$t/bytes"; image "$n" 1; info "$n"; printf 'networkaddress.cache.ttl=-1\n' > "$n/image/conf/net.properties"
run "$c/image" "$n/image"
[ "$rc" = 1 ] || fail "a native image whose conf/net.properties differs: exit $rc, not 1: $(cat "$t/out")"
has 'differs (not Mach-O): conf/net.properties' "a native image whose conf/net.properties differs"

n="$t/class"; image "$n" 1; info "$n"; unjmod "$n"; printf 'CAFEBABE Object2\n' > "$t/jm/classes/Object.class"; jmod "$n"
run "$c/image" "$n/image"
[ "$rc" = 1 ] || fail "a native jmod whose class differs: exit $rc, not 1: $(cat "$t/out")"
has 'differs (not Mach-O): jmods/java.base.jmod!classes/Object.class' "a native jmod whose class differs"

n="$t/jar"; image "$n" 1; info "$n"; rm -rf "$t/jm"; mkdir -p "$t/jm/jdk/internal/jrtfs"
printf 'CAFEBABE jrtfs2\n' > "$t/jm/jdk/internal/jrtfs/JrtFileSystem.class"; zipped "$t/jm"; cp "$t/z.zip" "$n/image/lib/jrt-fs.jar"
run "$c/image" "$n/image"
[ "$rc" = 1 ] || fail "a native jar whose class differs: exit $rc, not 1: $(cat "$t/out")"
has 'differs (not Mach-O): lib/jrt-fs.jar!jdk/internal/jrtfs/JrtFileSystem.class' "a native jar whose class differs"

n="$t/ctsym"; image "$n" 1 '' Object2; info "$n"
run "$c/image" "$n/image"
[ "$rc" = 1 ] || fail "a native jmod whose ct.sym holds a different entry: exit $rc, not 1: $(cat "$t/out")"
has 'differs (not Mach-O): jmods/java.base.jmod!lib/ct.sym!9/java.base/java/lang/Object.sig' "a native ct.sym entry that differs"

n="$t/createdby"; image "$n" 1 '25.0.5.0.3 (Mavergreen)'; info "$n"
run "$c/image" "$n/image"
[ "$rc" = 1 ] || fail "a native manifest whose Created-By differs, the boot JDK the same: exit $rc, not 1: $(cat "$t/out")"
has 'differs (not Mach-O): lib/jrt-fs.jar!META-INF/MANIFEST.MF:Created-By' "a native Created-By that differs, the boot JDK the same"

n="$t/manifest"; image "$n" 1 '25.0.5.0.3 (Mavergreen)' '' 'Main-Class: Other'; info "$n" bootjdk=jdk25-25.0.5.0.3+3-mavericks.1
run "$c/image" "$n/image"
[ "$rc" = 1 ] || fail "a native manifest that differs elsewhere than Created-By: exit $rc, not 1: $(cat "$t/out")"
has 'differs (not Mach-O): lib/jrt-fs.jar!META-INF/MANIFEST.MF$' "a native manifest that differs elsewhere than Created-By"
has "excused (bootjdk's jar wrote it): lib/jrt-fs.jar!META-INF/MANIFEST.MF:Created-By" "a native manifest that differs elsewhere than Created-By"

n="$t/modules"; image "$n" 1; info "$n"; printf 'another jimage\n' > "$n/image/lib/modules"
run "$c/image" "$n/image"
[ "$rc" = 1 ] || fail "a native lib/modules that differs while no Mach-O does: exit $rc, not 1: $(cat "$t/out")"
has 'differs (not Mach-O): lib/modules' "a native lib/modules that differs while no Mach-O does"

n="$t/modinfo"; image "$n" 2; info "$n"; unjmod "$n"; printf 'CAFEBABE 2\n' > "$t/jm/classes/module-info.class"; jmod "$n"
run "$c/image" "$n/image"
[ "$rc" = 1 ] || fail "a native module-info.class without ModuleHashes: exit $rc, not 1: $(cat "$t/out")"
has 'differs (not Mach-O): jmods/java.base.jmod!classes/module-info.class' "a native module-info.class without ModuleHashes"

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
