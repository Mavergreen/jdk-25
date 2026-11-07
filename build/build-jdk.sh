#!/bin/sh
# platform: macOS-only -- cross-builds the x86_64 Mac OS X 10.9 JDK on an arm64 Mac (jdk_boot_jdk, jdk_toolchain)
#   usage: sh build/build-jdk.sh
#          Fetches the pinned source into $(jdk_build_root)/src, applies patches/ with shipyard's
#          apply_patches.sh, configures and builds `make images` in $(jdk_build_root)/build, and
#          replaces $(jdk_build_root)/image with the JDK home and $(jdk_build_root)/test-natives with
#          the jtreg test natives (hotspot/jtreg/native and jdk/jtreg/native: tests/jtreg.sh's
#          JTREG_NATIVEPATH).
#          Writes $(jdk_build_root)/build-info.txt.
#          JDK_MAKE_JOBS sets make's job count (default: hw.ncpu).
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$SELF/.." && pwd)"; export MAVERICKS_ROOT
. "$SELF/toolchain.sh"

die() { echo "build-jdk: $*" >&2; exit 1; }

root="$(jdk_build_root)"
mkdir -p "$root"
jdk_toolchain || die "jdk_toolchain failed"
boot="$(jdk_boot_jdk)" || die "jdk_boot_jdk failed"
sdk="$SDKROOT"
# platform: configure requires CC and CXX to name one executable (TOOLCHAIN_FIND_COMPILER rejects
#           "path flags..."), so each carries jdk_toolchain's command line in a wrapper.
wrap="$root/toolchain/wrap"
mkdir -p "$wrap"
printf '#!/bin/sh\nexec %s "$@"\n' "$CC" > "$wrap/clang"
printf '#!/bin/sh\nexec %s "$@"\n' "$CXX" > "$wrap/clang++"
chmod +x "$wrap/clang" "$wrap/clang++"
CC="$wrap/clang"; CXX="$wrap/clang++"; export CC CXX
# platform: xcrun's /usr/bin/clang, which configure uses for the aarch64 build JDK, reads SDKROOT and
#           MACOSX_DEPLOYMENT_TARGET from the environment; left exported they aim that host build at the
#           10.9 SDK. The target build gets both as configure arguments instead.
unset SDKROOT MACOSX_DEPLOYMENT_TARGET

full="$(sh "$SHIPYARD_SCRIPTS/resolve-version.sh" auto)" || die "resolve-version.sh failed"
n="${full##*-mavericks.}"
case "$n" in ''|*[!0-9]*) die "version '$full' has no -mavericks.N" ;; esac

src="$root/src"
sh "$SELF/fetch-jdk.sh" "$src"
sh "$SHIPYARD_SCRIPTS/apply_patches.sh" "$src" "$MAVERICKS_ROOT/patches"

# platform: one word (-isystem<dir>), so the AppKit natives' CFLAGS_FILTER_OUT can remove exactly it:
#           Recaulk's headers back-fill the 10.9 SDK and redeclare what the 11.3 SDK already has
#           (pthread/qos.h's qos_class_t).
rflags="-isystem$RECAULK_INCLUDE"
# platform: every C++ binary (libjvm, libjsound, libfontmanager, jpackageapplauncher) compiles against
#           clang22's libc++ headers, so every link takes clang22's own libc++.a, hidden, and the system
#           libc++abi, as clang22's portable-ld does (ruling R21); the 10.9 SDK's libc++ lacks instantiations
#           those headers expect. -nostdlib++ keeps clang++ from adding -lc++ as well.
cxxlib="-nostdlib++ -Wl,-load_hidden,$CLANG22/lib/libc++.a -lc++abi"
# platform: those flags reach every link, C-only dylibs (libzip, libnet) too; -dead_strip_dylibs drops
#           the load command of any dylib a binary takes no symbol from, so only C++ binaries load libc++abi.
lflags="$RECAULK_LIB $cxxlib -Wl,-dead_strip_dylibs -Wl,-U,__availability_version_check -lobjc -framework CoreFoundation -framework Security -framework CoreServices"
vflags="-mmacosx-version-min=10.9"
repo_url=https://github.com/Mavergreen/jdk-25

# platform: configure takes the first clang on PATH as BUILD_CC for the aarch64 build JDK, and on a
#           Mavergreen Mac that is /usr/local/mavergreen/bin/clang, which targets x86_64 10.9; the
#           build JDK's tools (adlc) then cannot run on the arm64 host. configure reads BUILD_CC and
#           BUILD_CXX only as VAR=value arguments, not from the environment.
. "$MAVERICKS_ROOT/components/jdk/version"

# platform: configure makes man pages only with pandoc, which it reads as a VAR=value argument; jdk_pandoc
#           prints nothing on Mac OS X 10.9, where no pinned pandoc runs (ruling R19).
pandoc="$(jdk_pandoc)" || die "jdk_pandoc failed"
# platform: the jdk source's configure generates itself with the autoconf it finds as AUTOCONF, else the
#           first autoconf on PATH.
AUTOCONF="$(jdk_autoconf)" || die "jdk_autoconf failed"
export AUTOCONF
# spec: ruling R34 -- lib/security/cacerts holds the family ca-certs release's trusted roots, not
#       upstream's list; GenerateCacerts makes one entry per file, aliased "<file name> [jdk]".
cacerts="$(jdk_ca_certs)" || die "jdk_ca_certs failed"
out="$root/build"
rm -rf "$out"; mkdir -p "$out"
(cd "$out" && bash "$src/configure" \
  --openjdk-target=x86_64-apple-darwin \
  --with-boot-jdk="$boot" \
  --with-sysroot="$sdk" \
  --with-toolchain-type=clang \
  --with-extra-cflags="$vflags $rflags" \
  --with-extra-cxxflags="$vflags $rflags" \
  --with-extra-ldflags="$vflags -fuse-ld=lld $lflags" \
  --with-native-debug-symbols=none \
  --with-cacerts-src="$cacerts" \
  --disable-warnings-as-errors \
  --with-version-pre= \
  --with-version-build="${REF##*+}" \
  --with-version-opt="mavericks.$n" \
  --with-vendor-name=Mavergreen \
  --with-vendor-url="$repo_url" \
  --with-vendor-bug-url="$repo_url/issues" \
  --with-vendor-vm-bug-url="$repo_url/issues" \
  BUILD_CC=/usr/bin/clang BUILD_CXX=/usr/bin/clang++ ${pandoc:+"PANDOC=$pandoc"}) || die "configure failed (see $out/config.log)"

# platform: libawt_lwawt, libosxui, libosxapp and libsplashscreen use AppKit declarations from 10.10-11.0
#           that the 10.9 SDK lacks, so they alone compile and link against the family's pinned 11.3 SDK
#           (fetch_sdk.sh's arm64 pin) at deployment target 10.9, through the patches/ hook that reads
#           MAVERGREEN_APPKIT_SDK. INGREDIENTS.md declares each as an sdk-pin deviation, and the compat
#           guard still checks their imports and selectors against 10.9.
appkit_sdk="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch arm64)" || die "fetch_sdk.sh --arch arm64 failed"
MAVERGREEN_APPKIT_SDK="$appkit_sdk"; MAVERGREEN_APPKIT_CFLAGS_FILTER_OUT="$rflags"
export MAVERGREEN_APPKIT_SDK MAVERGREEN_APPKIT_CFLAGS_FILTER_OUT

jobs="${JDK_MAKE_JOBS:-$(sysctl -n hw.ncpu)}"
make -C "$out" JOBS="$jobs" images || die "make images failed"
# spec: ruling R29 -- the JNI libraries and launchers jtreg tests load, which tests/jtreg.sh passes
#       by -nativepath: the native part of make test-image only, not its compiled test classes.
# spec: ruling R39 -- test-image-lib-native builds test/lib's natives (libVThreadPinner, which the
#       virtual-thread pinning tests load) and make/test/BuildTestLibNative.gmk copies them into both
#       roots' jtreg/native, so the copy below carries them.
make -C "$out" JOBS="$jobs" test-image-hotspot-jtreg-native test-image-jdk-jtreg-native test-image-lib-native \
  || die "make test-image-hotspot-jtreg-native test-image-jdk-jtreg-native test-image-lib-native failed"

img="$out/images/jdk"
[ -x "$img/bin/java" ] || die "make images left no $img/bin/java"
rm -rf "$root/image"
cp -pR "$img" "$root/image"
rm -rf "$root/test-natives"
for r in hotspot jdk; do
  [ -d "$out/images/test/$r/jtreg/native" ] || die "make left no $out/images/test/$r/jtreg/native"
  mkdir -p "$root/test-natives/$r/jtreg"
  cp -pR "$out/images/test/$r/jtreg/native" "$root/test-natives/$r/jtreg/native"
done

features="$(sed -n 's/^JVM_FEATURES_server *:= *//p' "$out/spec.gmk" | tr ' ' ',')"
# spec: ruling R35 -- each SDK is recorded as its directory and the SHA-256 fetch_sdk.sh verified its
#       tarball against: shipyard's pin, or MAVERICKS_SDK_SHA256 over it.
# shellcheck disable=SC1091
. "$SHIPYARD_SCRIPTS/sdk-pins.sh"
# shellcheck disable=SC2046  # the pin is four space-free words by construction
sdk_pin() { set -- $(shipyard_sdk_pin "$1"); printf '%s@sha256:%s\n' "$4" "${MAVERICKS_SDK_SHA256:-$2}"; }
sh "$SHIPYARD_SCRIPTS/build-info.sh" "$root/build-info.txt" \
  "upstream=$(sh "$MAVERICKS_ROOT/build/derive-upstream-version.sh" --print)" \
  "jdk-ref=$REF@$DIGEST" \
  "bootjdk=$(sed -n 's/^TAG=//p' "$MAVERICKS_ROOT/components/bootjdk/version")" \
  "clang22=$(jdk_pin clang22)" \
  "recaulk=$(jdk_pin recaulk)" \
  "sdk=$(sdk_pin x86_64)" \
  "appkit-sdk=$(sdk_pin arm64)" \
  "ca-certs=$(jdk_pin ca-certs)" \
  "ca-certs-roots=$(find "$cacerts" -name '*.pem' | wc -l | tr -d ' ')" \
  "pandoc=$(if [ -n "$pandoc" ]; then sed -n 's/^VERSION=//p' "$MAVERICKS_ROOT/components/pandoc/version"; else echo none; fi)" \
  "features=$features"
echo "build-jdk: $root/image"
