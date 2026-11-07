# platform: macOS-only -- fetch_product_pkg.sh expands the clang22 and Recaulk pkgs with pkgutil
#   usage: . build/toolchain.sh; jdk_toolchain; jdk_boot_jdk
#          jdk_toolchain exports CC, CXX, AR, RANLIB, NM, CLANG22, CLANG22_BIN, SDKROOT,
#          MACOSX_DEPLOYMENT_TARGET (10.9), RECAULK_LIB (the pinned librecaulk.a) and RECAULK_INCLUDE for
#          x86_64, the only target. clang22 is the release components/clang22/version pins: on Mac OS X
#          10.9 the installed /usr/local/mavergreen/clang22, which must be that release; elsewhere the
#          clang22-cross pkg, extracted under the build root. CC never reads the driver's .cfg: target,
#          SDK (shipyard's fetch_sdk.sh pin) and linker (lld) are all explicit. Recaulk is the release
#          components/recaulk/version pins, extracted on every host.
#          jdk_boot_jdk prints the boot JDK's home. On Mac OS X 10.9 that is our own
#          /usr/local/mavergreen/jdk25, refused unless its bin/java runs; elsewhere the Temurin aarch64
#          build components/bootjdk/version pins (TAG, and the SHA256 of its tar.gz), fetched and verified
#          by shipyard's mavericks_fetch.sh into a cache under the build root, and its Contents/Home.
#          jdk_boot_jdk_id HOME prints what build-info.txt records as that boot JDK: on Mac OS X 10.9
#          jdk25-<HOME/release's JAVA_RUNTIME_VERSION>, elsewhere components/bootjdk/version's TAG.
#          jdk_target_args prints configure's --openjdk-target for the cross build, and nothing on Mac
#          OS X 10.9, which builds natively: there build, host and target are all x86_64 Darwin.
#          jdk_compat_guard MACHO... runs shipyard's compat guard on a JDK image's Mach-O, with the
#          deviations INGREDIENTS.md declares.
#          jdk_pandoc prints the pandoc components/pandoc/version pins (VERSION, and the SHA256 of its
#          macOS arm64 zip), which configure needs for man pages, fetched with shipyard_fetch_verified
#          into the build root, never installed. On Mac OS X 10.9 it prints nothing and says so: pandoc
#          publishes macOS builds for arm64, and for x86_64 macOS 15 or later only.
#          jdk_jtreg JDK_HOME prints the home of the jtreg components/jtreg/version pins (TAG, and the
#          SHA256 of GitHub's tarball of TAG). jtreg publishes no binaries, so the tarball is fetched
#          with shipyard_fetch_pinned into the build root and built there by its own make/build.sh with
#          JDK_HOME. build.sh downloads nothing: jdk_jtreg_fetch has already fetched the source and every
#          file components/jtreg/deps pins (scripts/pin-jtreg-deps.sh writes it), each with
#          shipyard_fetch_verified (retried, SHA-256 checked) into a cache under the build root, and
#          jdk_jtreg puts them where build.sh looks and runs it with --skip-download, its wget and curl
#          replaced by a command that refuses, so a download it still tries fails the build; build.sh's
#          own SHA-1 checks still run. A test tool only: nothing of it ships; the pin is the jtreg the
#          pinned jdk25u's CI runs, which tests/jtreg.sh checks.
#          jdk_jtreg_fetch fetches all of that and builds nothing; it refuses a components/jtreg/deps made
#          for another TAG before fetching anything.
#          jdk_autoconf prints the GNU autoconf components/autoconf/version pins (VERSION, and the SHA256
#          of its release tarball), built on the GNU m4 components/m4/version pins the same way, both
#          fetched with shipyard_fetch_pinned and built with /usr/bin/clang (the host's, as BUILD_CC) and
#          /usr/bin/perl into one prefix under the build root, never installed: OpenJDK's configure runs
#          autoconf to generate itself, and autoconf needs a GNU m4 newer than the 1.4.6 in /usr/bin on
#          Mac OS X 10.9 and on a modern Mac alike.
#          jdk_ca_certs prints the directory of trusted roots, one PEM per file, in the family ca-certs
#          release components/ca-certs/version pins, extracted under the build root on every host. Those
#          files are the roots of its ca-certificates.crt bundle, which configure's --with-cacerts-src
#          turns into lib/security/cacerts.
: "${MAVERICKS_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
. "$MAVERICKS_ROOT/build/msc.sh"

jdk_build_root() { _jbr="${TMPDIR:-/tmp}"; printf '%s/jdk-25\n' "${MAVERICKS_BUILD_ROOT:-${_jbr%/}/mm-build}"; }

jdk_pin() { tr -d '[:space:]' < "$MAVERICKS_ROOT/components/$1/version"; }

jdk_host_is_109() { [ "$(uname -s)" = Darwin ] && [ "$(uname -r | cut -d. -f1)" = 13 ]; }

jdk_installed_version() {
  awk '/<key>version<\/key>/ { getline; sub(/.*<string>/, ""); sub(/<\/string>.*/, ""); print; exit }' "$1/mavergreen.plist" 2>/dev/null
}

jdk_fetch_pkg() {
  _pf_short=$1; _pf_ver=$2; _pf_dest=$3; _pf_asset=${4:-}
  if [ -d "$_pf_dest" ] && [ "$(cat "$_pf_dest.pin" 2>/dev/null)" = "$_pf_ver" ]; then return 0; fi
  rm -f "$_pf_dest.pin"
  if [ -n "$_pf_asset" ]; then
    sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" --asset "$_pf_asset" "$_pf_short" "$_pf_ver" "$_pf_dest" >/dev/null || return 1
  else
    sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" "$_pf_short" "$_pf_ver" "$_pf_dest" >/dev/null || return 1
  fi
  printf '%s\n' "$_pf_ver" > "$_pf_dest.pin"
}

jdk_toolchain() {
  if [ "$(uname -s)" != Darwin ]; then
    echo "jdk_toolchain: clang22 and Recaulk arrive as pkgs, which only macOS can expand" >&2; return 1
  fi
  _pt_target=x86_64-apple-macos10.9; MACOSX_DEPLOYMENT_TARGET=10.9
  _pt_want="$(jdk_pin clang22)"
  if jdk_host_is_109; then
    CLANG22=/usr/local/mavergreen/clang22
    [ -x "$CLANG22/bin/clang" ] || {
      echo "jdk_toolchain: no clang22 at $CLANG22; install clang22 $_pt_want" >&2; return 1; }
    _pt_have="$(jdk_installed_version "$CLANG22")"
    [ "$_pt_have" = "$_pt_want" ] || {
      echo "jdk_toolchain: the installed clang22 is ${_pt_have:-of unknown version}, but components/clang22/version pins $_pt_want; install clang22 $_pt_want or move the pin" >&2
      return 1; }
  else
    CLANG22="$(jdk_build_root)/toolchain/clang22-cross-$_pt_want"
    jdk_fetch_pkg clang22-cross "$_pt_want" "$CLANG22" "mavericks-clang-22-cross-$_pt_want.pkg" || {
      echo "jdk_toolchain: could not fetch clang22-cross $_pt_want" >&2; return 1; }
  fi
  CLANG22_BIN="$CLANG22/bin"
  SDKROOT="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")" || return 1
  case "$SDKROOT" in
    ''|*' '*|*'	'*) echo "jdk_toolchain: the SDK path '$SDKROOT' is empty or has a space; CC carries it as one word" >&2; return 1 ;;
  esac
  _pt_flags="--no-default-config --target=$_pt_target -isysroot $SDKROOT -fuse-ld=lld -Wno-unused-command-line-argument"
  CC="$CLANG22_BIN/clang $_pt_flags"
  CXX="$CLANG22_BIN/clang++ $_pt_flags"
  AR="$CLANG22_BIN/llvm-ar"
  RANLIB="$CLANG22_BIN/llvm-ranlib"
  NM="$CLANG22_BIN/llvm-nm"
  export CLANG22 CLANG22_BIN SDKROOT MACOSX_DEPLOYMENT_TARGET CC CXX AR RANLIB NM
  _pt_rv="$(jdk_pin recaulk)"
  _pt_rd="$(jdk_build_root)/toolchain/recaulk-$_pt_rv"
  jdk_fetch_pkg recaulk "$_pt_rv" "$_pt_rd" || { echo "jdk_toolchain: could not fetch recaulk $_pt_rv" >&2; return 1; }
  RECAULK_LIB="$_pt_rd/lib/librecaulk.a"
  RECAULK_INCLUDE="$_pt_rd/include/recaulk"
  [ -f "$RECAULK_LIB" ] && [ -d "$RECAULK_INCLUDE" ] || {
    echo "jdk_toolchain: recaulk $_pt_rv has no lib/librecaulk.a or include/recaulk" >&2; return 1; }
  export RECAULK_LIB RECAULK_INCLUDE
}

jdk_boot_jdk() {
  if jdk_host_is_109; then
    _bj=/usr/local/mavergreen/jdk25
    [ -x "$_bj/bin/java" ] && "$_bj/bin/java" -version >/dev/null 2>&1 || {
      echo "jdk_boot_jdk: no working $_bj/bin/java; Mac OS X 10.9 builds with our own JDK 25, install a jdk25 release" >&2
      return 1; }
    printf '%s\n' "$_bj"; return 0
  fi
  _bj_tag="$(sed -n 's/^TAG=//p' "$MAVERICKS_ROOT/components/bootjdk/version" | tr -d '[:space:]')"
  _bj_sha="$(sed -n 's/^SHA256=//p' "$MAVERICKS_ROOT/components/bootjdk/version" | tr -d '[:space:]')"
  [ -n "$_bj_tag" ] && [ -n "$_bj_sha" ] || { echo "jdk_boot_jdk: components/bootjdk/version needs TAG and SHA256" >&2; return 1; }
  # platform: Temurin release URL path and asset name: jdk-25.0.5+8 -> jdk-25.0.5%2B8, OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.5_8.tar.gz
  _bj_asset="OpenJDK25U-jdk_aarch64_mac_hotspot_$(printf '%s' "${_bj_tag#jdk-}" | tr + _).tar.gz"
  _bj_url="https://github.com/adoptium/temurin25-binaries/releases/download/$(printf '%s' "$_bj_tag" | sed 's/+/%2B/')/$_bj_asset"
  _bj_cache="$(jdk_build_root)/bootjdk-$_bj_sha"
  _bj_home="$_bj_cache/$_bj_tag/Contents/Home"
  if [ ! -x "$_bj_home/bin/java" ]; then
    # shellcheck disable=SC1091
    . "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
    shipyard_fetch_pinned "$_bj_url" "$_bj_sha" "$_bj_cache" "$_bj_asset" >&2 || {
      echo "jdk_boot_jdk: could not fetch $_bj_tag" >&2; return 1; }
    [ -x "$_bj_home/bin/java" ] || { echo "jdk_boot_jdk: $_bj_asset has no $_bj_tag/Contents/Home/bin/java" >&2; return 1; }
  fi
  printf '%s\n' "$_bj_home"
}

jdk_boot_jdk_id() {
  if jdk_host_is_109; then
    _bi="$(sed -n 's/^JAVA_RUNTIME_VERSION="\(.*\)"$/\1/p' "$1/release" 2>/dev/null)"
    [ -n "$_bi" ] || { echo "jdk_boot_jdk_id: $1/release has no JAVA_RUNTIME_VERSION" >&2; return 1; }
    printf 'jdk25-%s\n' "$_bi"; return 0
  fi
  sed -n 's/^TAG=//p' "$MAVERICKS_ROOT/components/bootjdk/version" | tr -d '[:space:]'; echo
}

jdk_target_args() {
  jdk_host_is_109 || echo --openjdk-target=x86_64-apple-darwin
}

jdk_compat_guard() {
  # platform: libawt_lwawt names controlAccentColor (10.14) only inside patches/0016's
  #           @available(macOS 10.14, *) branch, so 10.9 never sends it.
  MAVERICKS_ALLOW_SELECTORS=controlAccentColor MAVERICKS_ALLOW_ARCHS=x86_64 \
    MAVERICKS_DEVIATIONS_ROOT="$MAVERICKS_ROOT" sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$@"
}

jdk_pandoc() {
  if jdk_host_is_109; then
    echo "jdk_pandoc: no pinned pandoc runs on Mac OS X 10.9; this build has no man pages" >&2; return 0
  fi
  [ "$(uname -m)" = arm64 ] || { echo "jdk_pandoc: the pinned pandoc is the macOS arm64 build" >&2; return 1; }
  _pd_ver="$(sed -n 's/^VERSION=//p' "$MAVERICKS_ROOT/components/pandoc/version" | tr -d '[:space:]')"
  _pd_sha="$(sed -n 's/^SHA256=//p' "$MAVERICKS_ROOT/components/pandoc/version" | tr -d '[:space:]')"
  [ -n "$_pd_ver" ] && [ -n "$_pd_sha" ] || { echo "jdk_pandoc: components/pandoc/version needs VERSION and SHA256" >&2; return 1; }
  _pd_asset="pandoc-$_pd_ver-arm64-macOS.zip"
  _pd_cache="$(jdk_build_root)/pandoc-$_pd_sha"
  _pd_bin="$_pd_cache/pandoc-$_pd_ver-arm64/bin/pandoc"
  if [ ! -x "$_pd_bin" ]; then
    # shellcheck disable=SC1091
    . "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
    shipyard_fetch_verified "https://github.com/jgm/pandoc/releases/download/$_pd_ver/$_pd_asset" \
      "$_pd_sha" "$_pd_cache" "$_pd_asset" >&2 || { echo "jdk_pandoc: could not fetch $_pd_asset" >&2; return 1; }
    (cd "$_pd_cache" && unzip -qo "$_pd_asset") || { echo "jdk_pandoc: could not unzip $_pd_asset" >&2; return 1; }
    [ -x "$_pd_bin" ] || { echo "jdk_pandoc: $_pd_asset has no pandoc-$_pd_ver-arm64/bin/pandoc" >&2; return 1; }
  fi
  printf '%s\n' "$_pd_bin"
}

_jdk_jtreg_pins() {
  _jt_tag="$(sed -n 's/^TAG=//p' "$MAVERICKS_ROOT/components/jtreg/version" | tr -d '[:space:]')"
  _jt_sha="$(sed -n 's/^SHA256=//p' "$MAVERICKS_ROOT/components/jtreg/version" | tr -d '[:space:]')"
  [ -n "$_jt_tag" ] && [ -n "$_jt_sha" ] || { echo "jdk_jtreg: components/jtreg/version needs TAG and SHA256" >&2; return 1; }
  _jt_deps="$MAVERICKS_ROOT/components/jtreg/deps"
  _jt_dtag="$(sed -n 's/^TAG=//p' "$_jt_deps" 2>/dev/null | tr -d ' \t\r')"
  [ "$_jt_dtag" = "$_jt_tag" ] || {
    echo "jdk_jtreg: components/jtreg/deps is for ${_jt_dtag:-no jtreg}, not $_jt_tag; run sh scripts/pin-jtreg-deps.sh" >&2; return 1; }
  _jt_ver="${_jt_tag#jtreg-}"
  _jt_cache="$(jdk_build_root)/jtreg-$_jt_sha"
  # platform: GitHub's tarball of tag jtreg-8+2 extracts to jtreg-jtreg-8-2, the tag with + made -
  _jt_src="$_jt_cache/jtreg-$(printf '%s' "$_jt_tag" | tr + -)"
  _jt_home="$_jt_cache/jtreg"
  _jt_dcache="$(jdk_build_root)/jtreg-deps"
}
jdk_jtreg_fetch() {
  _jdk_jtreg_pins || return 1
  # shellcheck disable=SC1091
  . "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
  if [ ! -d "$_jt_src" ]; then
    shipyard_fetch_pinned "https://github.com/openjdk/jtreg/archive/refs/tags/$_jt_tag.tar.gz" \
      "$_jt_sha" "$_jt_cache" "$_jt_tag.tar.gz" >&2 || { echo "jdk_jtreg: could not fetch $_jt_tag" >&2; return 1; }
  fi
  mkdir -p "$_jt_dcache"
  while read -r _jt_p _jt_s _jt_us; do
    case "$_jt_p" in TAG=*|'') continue ;; esac
    _jt_ok=no; _jt_left="$_jt_us"
    # platform: every URL but the last gets 2 tries, so a host that is down (archive.apache.org, for
    #           GitHub's runners) costs seconds, not shipyard_curl's full backoff, before its mirror; set in
    #           a subshell, since /bin/sh keeps an assignment prefixed to a function call, exported
    for _jt_u in $_jt_us; do
      _jt_left="${_jt_left#"$_jt_u"}"; _jt_left="${_jt_left# }"
      if [ -n "$_jt_left" ]; then
        if (SHIPYARD_FETCH_TRIES=2; export SHIPYARD_FETCH_TRIES
            shipyard_fetch_verified "$_jt_u" "$_jt_s" "$_jt_dcache" "$_jt_s") >&2; then _jt_ok=yes; break; fi
      elif shipyard_fetch_verified "$_jt_u" "$_jt_s" "$_jt_dcache" "$_jt_s" >&2; then _jt_ok=yes; break
      fi
    done
    [ "$_jt_ok" = yes ] || { echo "jdk_jtreg: could not fetch $_jt_p from any of: $_jt_us" >&2; return 1; }
  done < "$_jt_deps"
}
jdk_jtreg() {
  [ $# -eq 1 ] && [ -x "$1/bin/java" ] || { echo "jdk_jtreg: usage: jdk_jtreg JDK_HOME (a JDK with bin/java)" >&2; return 1; }
  _jdk_jtreg_pins || return 1
  if [ ! -x "$_jt_home/bin/jtreg" ]; then
    jdk_jtreg_fetch || return 1
    [ -f "$_jt_src/make/build.sh" ] || { echo "jdk_jtreg: $_jt_tag.tar.gz has no $(basename "$_jt_src")/make/build.sh" >&2; return 1; }
    while read -r _jt_p _jt_s _jt_us; do
      case "$_jt_p" in TAG=*|'') continue ;; esac
      mkdir -p "$(dirname "$_jt_src/build/deps/$_jt_p")" && cp "$_jt_dcache/$_jt_s" "$_jt_src/build/deps/$_jt_p" || {
        echo "jdk_jtreg: could not place $_jt_p" >&2; return 1; }
    done < "$_jt_deps"
    _jt_no="$_jt_cache/no-download"
    printf '#!/bin/sh\necho "jdk_jtreg: jtreg'"'"'s build.sh tried to download: $*; pin it in components/jtreg/deps (scripts/pin-jtreg-deps.sh)" >&2\nexit 1\n' > "$_jt_no"
    chmod +x "$_jt_no"
    # platform: build.sh takes WGET and CURL from the environment and, with --skip-download, downloads
    #           only what is not already in build/deps; its SHA-1 checks still run
    (cd "$_jt_src" && WGET="$_jt_no" CURL="$_jt_no" JTREG_BUILD_NUMBER="${_jt_ver##*+}" JTREG_VERSION_STRING="$_jt_ver" \
      bash make/build.sh --jdk "$1" --skip-download) >&2 || { echo "jdk_jtreg: make/build.sh failed for $_jt_tag" >&2; return 1; }
    rm -rf "$_jt_home" && mv "$_jt_src/build/images/jtreg" "$_jt_home" || { echo "jdk_jtreg: no build/images/jtreg from $_jt_tag" >&2; return 1; }
  fi
  printf '%s\n' "$_jt_home"
}

jdk_ca_certs() {
  _cc_v="$(jdk_pin ca-certs)"
  _cc_d="$(jdk_build_root)/toolchain/ca-certs-$_cc_v"
  jdk_fetch_pkg ca-certs "$_cc_v" "$_cc_d" || { echo "jdk_ca_certs: could not fetch ca-certs $_cc_v" >&2; return 1; }
  _cc_t="$_cc_d/share/ca-certs/trusted"
  ls "$_cc_t"/*.pem >/dev/null 2>&1 || { echo "jdk_ca_certs: ca-certs $_cc_v has no share/ca-certs/trusted/*.pem" >&2; return 1; }
  printf '%s\n' "$_cc_t"
}

# spec: PORT.md ruling R53 -- configure's autoconf is a pinned, fetched build input, not whatever a host
#       happens to have on PATH
jdk_autoconf() {
  _ac_v="$(sed -n 's/^VERSION=//p' "$MAVERICKS_ROOT/components/autoconf/version" | tr -d '[:space:]')"
  _ac_sha="$(sed -n 's/^SHA256=//p' "$MAVERICKS_ROOT/components/autoconf/version" | tr -d '[:space:]')"
  _m4_v="$(sed -n 's/^VERSION=//p' "$MAVERICKS_ROOT/components/m4/version" | tr -d '[:space:]')"
  _m4_sha="$(sed -n 's/^SHA256=//p' "$MAVERICKS_ROOT/components/m4/version" | tr -d '[:space:]')"
  [ -n "$_ac_v" ] && [ -n "$_ac_sha" ] && [ -n "$_m4_v" ] && [ -n "$_m4_sha" ] || {
    echo "jdk_autoconf: components/autoconf/version and components/m4/version need VERSION and SHA256" >&2; return 1; }
  [ -x /usr/bin/clang ] && [ -x /usr/bin/perl ] || {
    echo "jdk_autoconf: building GNU m4 and autoconf needs /usr/bin/clang and /usr/bin/perl" >&2; return 1; }
  _ac_root="$(jdk_build_root)/toolchain"
  _ac_pre="$_ac_root/autoconf-$_ac_v-$(printf '%s' "$_ac_sha" | cut -c1-12)-m4-$_m4_v-$(printf '%s' "$_m4_sha" | cut -c1-12)"
  if [ ! -f "$_ac_pre/.complete" ]; then
    # shellcheck disable=SC1091
    . "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
    _m4_src="$_ac_root/src-$_m4_sha/m4-$_m4_v"
    _ac_src="$_ac_root/src-$_ac_sha/autoconf-$_ac_v"
    for _ac_p in "m4 $_m4_v $_m4_sha" "autoconf $_ac_v $_ac_sha"; do
      set -- $_ac_p
      [ -d "$_ac_root/src-$3/$1-$2" ] && continue
      mkdir -p "$_ac_root/src-$3"
      shipyard_fetch_pinned "https://ftp.gnu.org/gnu/$1/$1-$2.tar.gz" "$3" "$_ac_root/src-$3" "$1-$2.tar.gz" >&2 \
        || { echo "jdk_autoconf: could not fetch $1-$2.tar.gz" >&2; return 1; }
    done
    rm -rf "$_ac_pre" "$_ac_root/build-m4-$_m4_v" "$_ac_root/build-autoconf-$_ac_v"
    mkdir -p "$_ac_root/build-m4-$_m4_v" "$_ac_root/build-autoconf-$_ac_v"
    _ac_jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
    # platform: jdk_toolchain exports CC, SDKROOT and MACOSX_DEPLOYMENT_TARGET for the x86_64 10.9 target,
    #           and configure and make read them from the environment.
    ( unset CC CXX CPP CFLAGS CXXFLAGS CPPFLAGS LDFLAGS SDKROOT MACOSX_DEPLOYMENT_TARGET M4 AUTOCONF AUTOM4TE
      cd "$_ac_root/build-m4-$_m4_v" \
        && "$_m4_src/configure" --prefix="$_ac_pre" --disable-nls CC=/usr/bin/clang \
        && make -j"$_ac_jobs" && make install \
        && cd "$_ac_root/build-autoconf-$_ac_v" \
        && "$_ac_src/configure" --prefix="$_ac_pre" M4="$_ac_pre/bin/m4" PERL=/usr/bin/perl \
        && make && make install ) >&2 || { echo "jdk_autoconf: building GNU m4 $_m4_v and autoconf $_ac_v failed" >&2; return 1; }
    rm -rf "$_ac_root/build-m4-$_m4_v" "$_ac_root/build-autoconf-$_ac_v"
    [ -x "$_ac_pre/bin/autoconf" ] && [ -x "$_ac_pre/bin/m4" ] || { echo "jdk_autoconf: no bin/autoconf or bin/m4 in $_ac_pre" >&2; return 1; }
    : > "$_ac_pre/.complete"
  fi
  printf '%s\n' "$_ac_pre/bin/autoconf"
}
