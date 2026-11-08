#!/bin/sh
# platform: macOS-only -- reads Mach-O with otool and nm, and runs shipyard's compat guard; executes nothing of the image
#   usage: sh tests/no-metal-test.sh IMAGE
#          JDK_BUILD=1 sh tests/no-metal-test.sh    (the image build/build-jdk.sh left in $(jdk_build_root)/image)
#          Java2D on 10.9 is OpenGL only (patches/0002, 0015 and 0021). Over every Mach-O in IMAGE and in its
#          jmods, it asserts:
#            no load command names Metal, MetalKit or MetalPerformanceShaders;
#            no undefined symbol is a Metal, MetalKit, MetalPerformanceShaders or CAMetalLayer class;
#            lib/shaders.metallib is absent;
#            the compat guard passes, selectors included (build/toolchain.sh's jdk_compat_guard).
#          Runs on any Mac, the 10.9 box included. Exits 77 when given no IMAGE and JDK_BUILD is not 1
#          (run-repo-tests runs it bare), 2 on bad usage.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
fail() { echo "FAIL $*" >&2; exit 1; }
[ "$#" -le 1 ] || { echo "usage: sh $0 IMAGE" >&2; exit 2; }
if [ "$#" -eq 0 ] && [ "${JDK_BUILD:-}" != 1 ]; then
  echo "SKIP no-metal: no image given (sh $0 IMAGE, or JDK_BUILD=1 after sh build/build-jdk.sh)"; exit 77
fi
[ "$(uname -s)" = Darwin ] || { echo "SKIP no-metal: needs macOS's otool and nm"; exit 77; }
. "$MAVERICKS_ROOT/build/toolchain.sh"
img="${1:-$(jdk_build_root)/image}"
[ -d "$img/jmods" ] || fail "no JDK image at $img (it has no jmods/)"
T="$(mktemp -d "${TMPDIR:-/tmp}/no-metal-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# platform: a jmod is a zip behind a 4-byte header, which unzip reads past with exit 1; jlink copies its
#           natives into the images it makes, so they ship too
for m in "$img"/jmods/*.jmod; do
  [ -f "$m" ] || fail "no jmods/*.jmod in $img"
  d="$T/jmods/$(basename "$m" .jmod)"; mkdir -p "$d"
  rc=0; unzip -qo "$m" -d "$d" 2> /dev/null || rc=$?
  [ "$rc" -le 1 ] || fail "unzip exited $rc on ${m#"$img"/}"
done
find "$img" "$T/jmods" -type f | while IFS= read -r f; do
  case "$(file -b "$f")" in Mach-O*) printf '%s\n' "$f" ;; esac
done > "$T/macho"
grep -q '/lib/libawt_lwawt\.dylib$' "$T/macho" || fail "no lib/libawt_lwawt.dylib among the Mach-O: Java2D's natives must be checked"

: > "$T/bad"
while IFS= read -r f; do
  otool -L "$f" | sed 1d | grep -E '/(Metal|MetalKit|MetalPerformanceShaders)\.framework/' | awk '{ print $1 }' \
    | while IFS= read -r l; do echo "${f#"$T"/} links $l" >> "$T/bad"; done
  nm -u "$f" 2> /dev/null | grep -E '^_OBJC_CLASS_\$_(MTL|MPS|MTK|CAMetalLayer)' \
    | while IFS= read -r s; do echo "${f#"$T"/} needs $s" >> "$T/bad"; done
done < "$T/macho"
[ ! -s "$T/bad" ] || { sed 's/^/  /' "$T/bad" >&2; fail "Metal reaches $(wc -l < "$T/bad" | tr -d ' ') place(s) in $img (Metal arrived in 10.11)"; }
echo "ok no Mach-O links or needs Metal, MetalKit or MetalPerformanceShaders ($(wc -l < "$T/macho" | tr -d ' ') Mach-O)"
[ ! -e "$img/lib/shaders.metallib" ] || fail "$img/lib/shaders.metallib exists: patches/0002 leaves the Metal shaders unbuilt"
echo "ok no lib/shaders.metallib"

# shellcheck disable=SC2046
jdk_compat_guard $(cat "$T/macho") > "$T/guard.out" 2>&1 \
  || { cat "$T/guard.out" >&2; fail "the compat guard refuses a Mach-O in $img"; }
echo "ok the compat guard passes, selectors included"
echo "PASS: no-metal ($img)"
