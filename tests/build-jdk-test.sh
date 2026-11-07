#!/bin/sh
# platform: macOS-only -- reads Mach-O with otool and shipyard's compat guard
# usage: JDK_BUILD=1 sh tests/build-jdk-test.sh
#   Checks the image build/build-jdk.sh left in $(jdk_build_root)/image, or JDK_IMAGE, with its test natives
#   (JDK_TEST_NATIVES) and build-info.txt (JDK_BUILD_INFO) beside it. Exits 77 (skip) unless JDK_BUILD=1,
#   and off macOS. Every static check runs on any Mac; the default-headless and keytool -cacerts checks
#   execute the image, so they run only where this host's CPU runs the image's bin/java natively
#   (tests/lib/host-cpu.sh: Mac OS X 10.9). Anywhere else (an arm64 Mac, Rosetta or not) nothing of the
#   image is executed: the static checks decide PASS or FAIL, cacerts is read with the boot JDK's keytool,
#   and the run exits 77 naming what it left to tests/smoke-mavericks.sh in the 10.9 guest.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
fail() { echo "FAIL $*" >&2; exit 1; }
[ "${JDK_BUILD:-}" = 1 ] || { echo "SKIP: set JDK_BUILD=1 after sh build/build-jdk.sh"; exit 77; }
[ "$(uname -s)" = Darwin ] || { echo "SKIP: build-jdk needs macOS"; exit 77; }

. "$MAVERICKS_ROOT/build/toolchain.sh"
. "$here/lib/host-cpu.sh"
img="${JDK_IMAGE:-$(jdk_build_root)/image}"
[ -d "$img" ] || fail "no image at $img; run sh build/build-jdk.sh"
for d in bin lib conf jmods include legal man release; do
  [ -e "$img/$d" ] || fail "image lacks $d: a JDK home has bin lib conf jmods include legal man release"
done

u="$(sh "$MAVERICKS_ROOT/build/derive-upstream-version.sh" --print)"
grep -qx "JAVA_VERSION=\"$u\"" "$img/release" \
  || fail "release says $(grep '^JAVA_VERSION=' "$img/release"), not JAVA_VERSION=\"$u\" from UPSTREAM_VERSION"

T="$(mktemp -d "${TMPDIR:-/tmp}/build-jdk-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
if find "$img" -name '*.dSYM' | grep -q .; then
  fail "image has .dSYM bundles: configure --with-native-debug-symbols=none (ruling R20)"
fi
# platform: each jmods/*.jmod is a zip behind a 4-byte header, which unzip reads past; jlink copies
#           its natives and resources (jpackageapplauncher among them) into images it makes, so they
#           are shipped Mach-O too. unzip exits 1 for that header's warning, 2 and up on a real failure.
for m in "$img"/jmods/*.jmod; do
  d="$T/jmods/$(basename "$m" .jmod)"; mkdir -p "$d"
  rc=0; unzip -qo "$m" -d "$d" 2>/dev/null || rc=$?
  [ "$rc" -le 1 ] || fail "unzip exited $rc on ${m#"$img"/}"
done
find "$img" "$T/jmods" -type f | while IFS= read -r f; do
  case "$(file -b "$f")" in Mach-O*) printf '%s\n' "$f" ;; esac
done > "$T/macho"
[ -s "$T/macho" ] || fail "no Mach-O found under $img"
grep -q '/lib/server/libjvm\.dylib$' "$T/macho" || fail "no lib/server/libjvm.dylib among the image's Mach-O"
grep -q '/lib/libawt_lwawt\.dylib$' "$T/macho" || fail "no lib/libawt_lwawt.dylib: java.desktop is built in full (ruling R10), so the guard must see it"

sdk="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")" || fail "fetch_sdk.sh failed"
while IFS= read -r f; do
  # platform: a sub-framework's install name nests inside its umbrella (JavaVM.framework/Versions/A/
  #           Frameworks/JavaRuntimeSupport.framework), so the whole path up to the last .framework is
  #           what the 10.9 SDK must have.
  otool -L "$f" | sed -n 's|^[[:space:]]*\(/System/Library/Frameworks/.*\.framework\)/.*|\1|p' | sort -u | while IFS= read -r fw; do
    [ -d "$sdk$fw" ] \
      || { echo "FAIL ${f#"$img"/} links $fw, which the 10.9 SDK does not have" >&2; exit 1; }
  done || exit 1
  # platform: clang22's libc++ is linked into each C++ binary, hidden (ruling R21); a libc++.1.dylib
  #           load command means a link took the 10.9 SDK's libc++ instead.
  if otool -L "$f" | grep -q '/libc++\.1\.dylib '; then
    echo "FAIL ${f#"$img"/} links libc++.1.dylib, not clang22's own libc++ (ruling R21)" >&2; exit 1
  fi
done < "$T/macho"
if otool -L "$img/lib/server/libjvm.dylib" | grep -Eq '/(Metal|MetalKit)\.framework/'; then
  fail "lib/server/libjvm.dylib links Metal, which arrived in 10.11"
fi

# platform: libawt_lwawt names controlAccentColor (10.14) only inside patches/0016's
#           @available(macOS 10.14, *) branch, so 10.9 never sends it.
# shellcheck disable=SC2046
MAVERICKS_ALLOW_SELECTORS=controlAccentColor \
MAVERICKS_ALLOW_ARCHS=x86_64 MAVERICKS_DEVIATIONS_ROOT="$MAVERICKS_ROOT" \
  sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" $(cat "$T/macho") > "$T/guard.out" 2>&1 \
  || { cat "$T/guard.out" >&2; fail "the compat guard refuses a Mach-O in the image"; }
echo "ok static: $(wc -l < "$T/macho" | tr -d ' ') Mach-O pass the compat guard"

# platform: -dead_strip_dylibs keeps R21's -lc++abi only in binaries that take a symbol from it; libzip
#           is C, so a libc++abi load command there means the link kept every -l it was given.
if otool -L "$img/lib/libzip.dylib" | grep -q '/libc++abi\.dylib '; then
  fail "lib/libzip.dylib, which is C, links libc++abi.dylib: the links lack -Wl,-dead_strip_dylibs"
fi

# spec: PORT.md ruling R18 -- decided by the host's CPU, never by trying: under Rosetta the image would run
executes=no
if jdk_runs_natively "$img"; then executes=yes; fi

# spec: ruling R34 -- lib/security/cacerts is the pinned ca-certs release's trusted roots, one entry per
#       PEM. The image's own keytool reads it where the image runs natively, as on Mac OS X 10.9, which may
#       have no boot JDK installed; the boot JDK's everywhere else.
roots="$(jdk_ca_certs)" || fail "jdk_ca_certs failed"
if [ "$executes" = yes ]; then keytool="$img/bin/keytool"
else boot="$(jdk_boot_jdk)" || fail "jdk_boot_jdk failed"; keytool="$boot/bin/keytool"
fi
"$keytool" -list -keystore "$img/lib/security/cacerts" < /dev/null > "$T/cacerts" 2>&1 \
  || { cat "$T/cacerts" >&2; fail "keytool cannot list lib/security/cacerts"; }
want="$(find "$roots" -name '*.pem' | wc -l | tr -d ' ')"
grep -q "^Your keystore contains $want entries\$" "$T/cacerts" \
  || fail "lib/security/cacerts: $(grep '^Your keystore contains' "$T/cacerts" || echo 'no count'), but ca-certs $(jdk_pin ca-certs) has $want trusted roots"
# platform: ISRG Root X1 (SHA-1 CA:BD:2A:79:...), Let's Encrypt's root; a file name's alias is lowercase
grep -q '^cabd2a79a1076a31f21d253635cb039d4329a5e8\.pem \[jdk\],' "$T/cacerts" \
  || fail "lib/security/cacerts has no ISRG Root X1 (cabd2a79a1076a31f21d253635cb039d4329a5e8.pem [jdk])"
echo "ok cacerts: $want roots from ca-certs $(jdk_pin ca-certs)"
# spec: PORT.md ruling R18 -- tests/smoke-mavericks.sh checks the installed JDK's keytool -cacerts against
#       this count in the 10.9 guest, which cannot fetch ca-certs itself, so build-info.txt carries it
grep -qx "ca-certs-roots=$want" "${JDK_BUILD_INFO:-$(jdk_build_root)/build-info.txt}" \
  || fail "build-info.txt does not record ca-certs-roots=$want"

# spec: ruling R29 -- the jtreg test natives build-jdk.sh leaves beside the image, for tests/jtreg.sh's
#       JTREG_NATIVEPATH on Mac OS X 10.9: present for both roots, and built for x86_64 only: a universal
#       binary's file(1) line names x86_64 too, so it is refused first.
nat="${JDK_TEST_NATIVES:-$(jdk_build_root)/test-natives}"
for r in hotspot jdk; do
  [ -n "$(ls "$nat/$r/jtreg/native" 2>/dev/null)" ] || fail "no test natives in $nat/$r/jtreg/native"
  find "$nat/$r/jtreg/native" -type f | while IFS= read -r f; do
    case "$(file -b "$f")" in
      Mach-O\ universal*) echo "FAIL ${f#"$nat"/} is universal, not x86_64 only: $(file -b "$f")" >&2; exit 1 ;;
      Mach-O*x86_64*) ;;
      Mach-O*) echo "FAIL ${f#"$nat"/} is not x86_64: $(file -b "$f")" >&2; exit 1 ;;
    esac
  done || exit 1
done
# spec: ruling R39 -- test/lib's libVThreadPinner, from test-image-lib-native, in both roots; the loop
#       above has already held it to x86_64 only.
for r in hotspot jdk; do
  [ -f "$nat/$r/jtreg/native/libVThreadPinner.dylib" ] \
    || fail "no $r/jtreg/native/libVThreadPinner.dylib in $nat: build-jdk.sh skipped test-image-lib-native"
done

# spec: ruling R35 -- build/build-jdk.sh records each SDK as <dir>@sha256:<verified pin>, under its own key
# shellcheck disable=SC1091
. "$SHIPYARD_SCRIPTS/sdk-pins.sh"
info="${JDK_BUILD_INFO:-$(jdk_build_root)/build-info.txt}"
for ak in x86_64:sdk arm64:appkit-sdk; do
  # shellcheck disable=SC2046  # the pin is four space-free words by construction
  set -- $(shipyard_sdk_pin "${ak%%:*}")
  grep -Fqx "${ak#*:}=$4@sha256:$2" "$info" || fail "$info does not record ${ak#*:}=$4@sha256:$2"
done

if [ "$executes" = no ]; then
  echo "SKIP headless-default, keytool-cacerts: this host's CPU does not run the image's x86_64 natively (PORT.md ruling R18); tests/smoke-mavericks.sh checks the installed JDK in the 10.9 guest"
  exit 77
fi
"$img/bin/java" -XshowSettings:properties -version > "$T/props" 2>&1 \
  || { cat "$T/props" >&2; fail "bin/java -XshowSettings:properties -version failed"; }
grep -Eq '^ +java\.awt\.headless = true$' "$T/props" \
  || fail "java.awt.headless is not true by default: $(grep 'java.awt.headless' "$T/props" || echo unset)"
"$img/bin/keytool" -list -cacerts < /dev/null > "$T/own-cacerts" 2>&1 \
  || { cat "$T/own-cacerts" >&2; fail "the image's keytool -list -cacerts failed"; }
grep -q "^Your keystore contains $want entries\$" "$T/own-cacerts" \
  || fail "the image's keytool -list -cacerts: $(grep '^Your keystore contains' "$T/own-cacerts" || echo 'no count'), not $want"
echo "PASS: build-jdk"
