#!/bin/sh
# platform: macOS-only -- builds a Cocoa app against the 10.9 SDK with jdk_toolchain's clang22
#   usage: build/build-updater.sh --out APP
#          Builds the x86_64 Sparkle updater (CMakeLists.txt) with jdk_toolchain's clang22 and shipyard's
#          MavericksToolchain.cmake (10.9 SDK, minos 10.9) in a fresh $(jdk_build_root)/updater.XXXXXX,
#          removed afterwards, and copies jdk25-updater.app to APP, which must not exist. x86_64 only:
#          the JDK it updates is x86_64 only. Its version is mavericks_resolve_version's, which reads
#          VERSION when one exists.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$here/toolchain.sh"

usage() { echo "usage: build/build-updater.sh --out APP" >&2; exit 2; }
die() { echo "build-updater: $*" >&2; exit 1; }
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || usage; out=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$out" ] || usage
case "$out" in /*) ;; *) out="$(pwd)/$out" ;; esac
[ ! -e "$out" ] && [ ! -L "$out" ] || die "$out already exists"
cmake_bin="$(command -v shipyard-cmake || echo /usr/local/mavergreen/bin/shipyard-cmake)"
[ -x "$cmake_bin" ] || die "no shipyard-cmake; install the shipyard pkg"
tc="$(dirname "$SHIPYARD_SCRIPTS")/MavericksToolchain.cmake"
[ -f "$tc" ] || die "no MavericksToolchain.cmake beside $SHIPYARD_SCRIPTS"

mkdir -p "$(jdk_build_root)"
work="$(mktemp -d "$(jdk_build_root)/updater.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# spec: .superpowers/QUEUE.md "jdk25 updater artwork" -- updater/jdk25-updater.icns is a generated
#       placeholder registered in shipyard's scripts/placeholder-icons.sha256, so this build opts in to
#       it on purpose until real artwork replaces it; then this flag goes.
( jdk_toolchain > /dev/null \
  && "$cmake_bin" -S "$MAVERICKS_ROOT" -B "$work/x86_64" \
    -DCMAKE_TOOLCHAIN_FILE="$tc" -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    -DCMAKE_OBJC_COMPILER="$CLANG22_BIN/clang" -DCMAKE_OBJC_FLAGS=--no-default-config \
    -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld -DMAVERICKS_ALLOW_GENERIC_ICON=ON \
  && "$cmake_bin" --build "$work/x86_64" ) >&2 || die "the x86_64 updater did not build"
mkdir -p "$(dirname "$out")"
cp -Rp "$work/x86_64/jdk25-updater.app" "$out"
echo "build-updater: x86_64 updater at $out" >&2
