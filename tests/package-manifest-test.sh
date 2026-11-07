#!/bin/sh
# platform: macOS-only -- build/package-pkg.sh runs stevedore and productbuild, and PlistBuddy reads what it made
#   usage: [JDK_PACKAGE_REAL=1 [JDK_UPDATER_APP=APP]] tests/package-manifest-test.sh
#          Packages a tiny stand-in image with build/package-pkg.sh, expands the pkg with stevedore and
#          runs its postinstall against a scratch volume: the components, Distribution, payload, manifest,
#          .jdk bundle, legend, farm links and the CDS step are what the family and this product expect.
#          With JDK_PACKAGE_REAL=1 it also packages the image build/build-jdk.sh left in
#          $(jdk_build_root)/image (or JDK_IMAGE), with JDK_UPDATER_APP or an updater
#          build/build-updater.sh builds, and runs shipyard's artifact conformance over it.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$MAVERICKS_ROOT/build/toolchain.sh"
package="$MAVERICKS_ROOT/build/package-pkg.sh"
short=jdk25
prefix=/usr/local/mavergreen/$short
jdkdir=Library/Java/JavaVirtualMachines/mavergreen-jdk25.jdk
legend="Java and OpenJDK are trademarks or registered trademarks of Oracle and/or its affiliates."
up="$(sh "$MAVERICKS_ROOT/build/derive-upstream-version.sh" --print)"
V="$up-mavericks.7"
id="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" identifier "$short")"
upd_id="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" updater-bundle-id "$short")"
feed="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" feed "$short")"
upd_rel="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" updater-app "$short")"
label="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" agent-label "$short")"
STEVEDORE="$(sh "$SHIPYARD_SCRIPTS/fetch_stevedore.sh")"
mkdir -p "$(jdk_build_root)"
t="$(mktemp -d "$(jdk_build_root)/package-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $*"; exit 1; }
PB=/usr/libexec/PlistBuddy

printf '\317\372\355\376\007\000\000\001\003\000\000\000\002\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' > "$t/x86_64-header"

tiny_image() {
  s="$1"
  mkdir -p "$s/bin" "$s/lib/server" "$s/legal/java.base" "$s/conf"
  cat > "$s/bin/java" <<'EOF'
#!/bin/sh
d="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$d/java-runs"
if [ -f "$d/fail-dump" ]; then echo "Error occurred during initialization of VM" >&2; exit 1; fi
echo "Dumping shared data"
EOF
  printf '#!/bin/sh\necho javac %s\n' "$up" > "$s/bin/javac"
  chmod +x "$s/bin/java" "$s/bin/javac"
  cp "$t/x86_64-header" "$s/lib/server/libjvm.dylib"
  cp "$t/x86_64-header" "$s/lib/libjli.dylib"
  printf 'GPLv2 with the Classpath Exception\n' > "$s/legal/java.base/LICENSE"
  printf 'JAVA_VERSION="%s"\nJAVA_RUNTIME_VERSION="%s+1-mavericks.7"\nOS_ARCH="x86_64"\n' "$up" "$up" > "$s/release"
}

tiny_updater() {
  a="$1/$short-updater.app/Contents"
  mkdir -p "$a/MacOS"
  cp "$t/x86_64-header" "$a/MacOS/$short-updater"
  cat > "$a/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$upd_id</string>
<key>CFBundleExecutable</key><string>$short-updater</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$2</string>
<key>SUFeedURL</key><string>$feed</string>
</dict></plist>
EOF
}

expand() {
  rm -rf "$t/x" "$t/root" "$t/scripts"
  "$STEVEDORE" expand "$1" "$t/x" > /dev/null || fail "stevedore could not expand $1"
  mkdir -p "$t/root" "$t/scripts"
  for c in "$t/x"/*.pkg; do
    tar -xf "$c/Payload" -C "$t/root" || fail "could not read $c/Payload"
  done
  for c in "$t/x"/*.pkg; do
    if [ "$(sed -n 's/.*<pkg-info[^>]* identifier="\([^"]*\)".*/\1/p' "$c/PackageInfo")" = "$id" ]; then
      cp -R "$c/Scripts/." "$t/scripts/"
    fi
  done
  [ -x "$t/scripts/postinstall" ] || fail "the $id component has no postinstall"
}

check_pkg() {
  dist="$t/x/Distribution"
  comps="$(sed -n 's/.*<pkg-ref id="\([^"]*\)".*/\1/p' "$dist" | awk '!seen[$0]++' | tr '\n' ' ')"
  [ "$comps" = "dev.mavergreen.base $id " ] || fail "components are '$comps', not dev.mavergreen.base then $id"
  grep -q 'hostArchitectures="x86_64"' "$dist" || fail "Distribution does not declare hostArchitectures=\"x86_64\": $(grep hostArch "$dist")"
  grep -q '<title>JDK 25 for Mavericks</title>' "$dist" || fail "Distribution's title is not JDK 25 for Mavericks"
  grep -q '<os-version[^>]*min="10\.9\.5"' "$dist" || fail "Distribution declares no 10.9.5 floor: $(grep os-version "$dist")"
  grep -q '<license file="LICENSE.txt"' "$dist" || fail "Distribution shows no license"
  grep -q '<welcome file="Welcome.html"' "$dist" || fail "Distribution shows no welcome"

  ( cd "$t/root" && find . \( -type f -o -type l \) | sed 's|^\./||' ) > "$t/files"
  stray="$(grep -v -e "^usr/local/mavergreen/$short/" -e "^$upd_rel/" -e "^Library/LaunchAgents/$label\.plist$" \
    -e '^usr/local/mavergreen/\.base/' -e "^$jdkdir/Contents/Info\.plist$" -e "^$jdkdir/Contents/Home$" -e "^$jdkdir/Contents/MacOS/libjli\.dylib$" "$t/files" || true)"
  [ -z "$stray" ] || fail "the payload installs outside $prefix, the .jdk bundle and the updater: $stray"
  grep -q "^$upd_rel/Contents/Info.plist$" "$t/files" || fail "the payload has no $upd_rel"
  grep -q "^Library/LaunchAgents/$label\.plist$" "$t/files" || fail "the payload has no $label agent"
  [ -z "$(find "$t/root/$jdkdir" \( -type f -o -type l \) | grep -v -e '/Contents/Info\.plist$' -e '/Contents/Home$' -e '/Contents/MacOS/libjli\.dylib$')" ] \
    || fail "the .jdk bundle holds more than Contents/Info.plist, Contents/Home and Contents/MacOS/libjli.dylib: $(find "$t/root/$jdkdir")"

  m="$t/root$prefix/mavergreen.plist"
  [ "$("$PB" -c 'Print :identifier' "$m")" = "$id" ] || fail "manifest identifier is not $id"
  [ "$("$PB" -c 'Print :product' "$m")" = "$short" ] || fail "manifest product is not $short"
  [ "$("$PB" -c 'Print :group' "$m")" = jdk ] || fail "manifest group is not jdk"
  [ "$("$PB" -c 'Print :line' "$m")" = 25 ] || fail "manifest line is not 25"
  [ "$("$PB" -c 'Print :version' "$m")" = "$V" ] || fail "manifest version is not $V"
  [ "$("$PB" -c 'Print :appcast' "$m")" = "$feed" ] || fail "manifest appcast is not $feed"
  i=0; : > "$t/outside"
  while o="$("$PB" -c "Print :outside:$i" "$m" 2>/dev/null)"; do echo "$o" >> "$t/outside"; i=$((i + 1)); done
  # spec: PORT.md ruling R41 -- shipyard's render-manifest.sh
  #       folds a .jdk like an .app, so preinstall and uninstall clear the bundle whole.
  printf '%s\n' "Library/Application Support/Mavergreen/$short-updater.app" "Library/LaunchAgents/$label.plist" \
    "$jdkdir" | LC_ALL=C sort > "$t/outside-want"
  LC_ALL=C sort "$t/outside" | cmp -s - "$t/outside-want" \
    || fail "manifest outside is '$(tr '\n' '|' < "$t/outside")', not the .jdk bundle, the updater and its agent"

  : > "$t/legend"
  for f in "$t/root$prefix/legal"/*; do
    if [ -f "$f" ] && grep -qxF "$legend" "$f"; then echo "${f##*/}" >> "$t/legend"; fi
  done
  [ -s "$t/legend" ] || fail "no file in $prefix/legal/ carries the trademark legend verbatim"

  ip="$t/root/$jdkdir/Contents/Info.plist"
  [ "$("$PB" -c 'Print :CFBundleIdentifier' "$ip")" = dev.mavergreen.jdk.jdk25.jdk ] || fail "the .jdk's CFBundleIdentifier is not dev.mavergreen.jdk.jdk25.jdk"
  [ "$("$PB" -c 'Print :CFBundleName' "$ip")" = "Mavericks JDK 25" ] || fail "the .jdk's CFBundleName is not Mavericks JDK 25"
  [ "$("$PB" -c 'Print :JavaVM:JVMVersion' "$ip")" = "$up" ] || fail "JVMVersion is not $up"
  [ "$("$PB" -c 'Print :JavaVM:JVMPlatformVersion' "$ip")" = 25 ] || fail "JVMPlatformVersion is not 25"
  [ "$("$PB" -c 'Print :JavaVM:JVMVendor' "$ip")" = Mavergreen ] || fail "JVMVendor is not Mavergreen"
  [ "$("$PB" -c 'Print :JavaVM:JVMMinimumSystemVersion' "$ip")" = 10.9 ] || fail "JVMMinimumSystemVersion is not 10.9"
  caps="$("$PB" -c 'Print :JavaVM:JVMCapabilities' "$ip" | sed -n 's/^ *\([A-Za-z]*\)$/\1/p' | tr '\n' ' ')"
  [ "$caps" = "CommandLine JNI BundledApp " ] || fail "JVMCapabilities are '$caps', not CommandLine JNI BundledApp"
  [ "$(readlink "$t/root/$jdkdir/Contents/Home")" = "$prefix" ] || fail "Contents/Home links to $(readlink "$t/root/$jdkdir/Contents/Home"), not $prefix"
  [ "$("$PB" -c 'Print :CFBundleExecutable' "$ip")" = libjli.dylib ] || fail "the .jdk's CFBundleExecutable is not libjli.dylib"
  jli="$(readlink "$t/root/$jdkdir/Contents/MacOS/libjli.dylib")" || fail "the .jdk has no Contents/MacOS/libjli.dylib link"
  case "$jli" in
    ../Home/*) [ -f "$t/root$(readlink "$t/root/$jdkdir/Contents/Home")/${jli#../Home/}" ] \
      || fail "Contents/MacOS/libjli.dylib -> $jli does not resolve to a file in the staged Home" ;;
    *) fail "Contents/MacOS/libjli.dylib links to $jli, not into ../Home" ;;
  esac
  [ "$jli" = ../Home/lib/libjli.dylib ] || fail "Contents/MacOS/libjli.dylib links to $jli, not ../Home/lib/libjli.dylib"
  grep -q -- '-Xshare:dump' "$t/scripts/postinstall" || fail "the postinstall has no -Xshare:dump step"
  :
}

run_postinstall() {
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$t/scripts/postinstall" "$1" / "$t/root" > "$t/post.out" 2>&1
}

mkdir -p "$t/img" "$t/upd" "$t/out"
tiny_image "$t/img"
printf 'upstream=%s\nsdk=MacOSX10.9.sdk@sha256:0\n' "$up" > "$t/build-info.txt"
export JDK_IMAGE="$t/img" JDK_BUILD_INFO="$t/build-info.txt"
tiny_updater "$t/upd" "$up-mavericks.6"
if sh "$package" --updater-app "$t/upd/$short-updater.app" --version "$V" --out "$t/out" > "$t/o" 2>&1; then
  fail "package-pkg took an updater at another version"
fi
grep -q "$up-mavericks.6" "$t/o" || fail "the version refusal does not name the updater's version: $(cat "$t/o")"
rm -rf "$t/upd"; mkdir "$t/upd"; tiny_updater "$t/upd" "25.0.3-mavericks.7"
if sh "$package" --updater-app "$t/upd/$short-updater.app" --version "25.0.3-mavericks.7" --out "$t/out" > "$t/o" 2>&1; then
  fail "package-pkg took a version that is not the image's"
fi
grep -q "not the image's JAVA_VERSION $up" "$t/o" || fail "the version refusal does not name the image's version: $(cat "$t/o")"
rm -rf "$t/upd"; mkdir "$t/upd"; tiny_updater "$t/upd" "$up-mavericks.8"
if sh "$package" --updater-app "$t/upd/$short-updater.app" --version "$up-mavericks.8" --out "$t/out" > "$t/o" 2>&1; then
  fail "package-pkg took a -mavericks.N that is not the image's build"
fi
grep -q "JAVA_RUNTIME_VERSION is $up+1-mavericks.7" "$t/o" || fail "the build refusal does not name the image's runtime version: $(cat "$t/o")"
sed -i.bak 's/^JAVA_VERSION=.*/JAVA_VERSION="25.0.3"/' "$t/img/release"
rm -rf "$t/upd"; mkdir "$t/upd"; tiny_updater "$t/upd" "25.0.3-mavericks.7"
if sh "$package" --updater-app "$t/upd/$short-updater.app" --version "25.0.3-mavericks.7" --out "$t/out" > "$t/o" 2>&1; then
  fail "package-pkg packaged an image that is not UPSTREAM_VERSION's JDK"
fi
grep -q "the image is JDK 25.0.3, but UPSTREAM_VERSION is $up" "$t/o" || fail "the upstream refusal does not name both versions: $(cat "$t/o")"
mv "$t/img/release.bak" "$t/img/release"
rm -rf "$t/upd"; mkdir "$t/upd"; tiny_updater "$t/upd" "$V"
mv "$t/img/lib/libjli.dylib" "$t/jli"
if sh "$package" --updater-app "$t/upd/$short-updater.app" --version "$V" --out "$t/out" > "$t/o" 2>&1; then
  fail "package-pkg packaged an image without lib/libjli.dylib"
fi
grep -q "lib/libjli.dylib" "$t/o" || fail "the libjli refusal does not name it: $(cat "$t/o")"
mv "$t/jli" "$t/img/lib/libjli.dylib"
mv "$t/build-info.txt" "$t/bi"
if JDK_BUILD_INFO="$t/build-info.txt" sh "$package" --updater-app "$t/upd/$short-updater.app" --version "$V" --out "$t/out" > "$t/o" 2>&1; then
  fail "package-pkg packaged an image without its build-info.txt"
fi
mv "$t/bi" "$t/build-info.txt"
[ -z "$(ls "$t/out")" ] || fail "a refused packaging left $(ls "$t/out") behind"
sh "$package" --updater-app "$t/upd/$short-updater.app" --version "$V" --out "$t/out" > "$t/o" 2>&1 \
  || fail "package-pkg failed on the tiny image: $(cat "$t/o")"
pkg="$t/out/jdk-$V.pkg"
[ -f "$pkg" ] || fail "no $pkg: $(ls "$t/out")"
bi="$t/out/build-info-jdk25.txt"
for kv in "upstream=$up" "sdk=MacOSX10.9.sdk@sha256:0" "variant=$short" arch=x86_64 "prefix=$prefix" \
  "identifier=$id" "version=$V" "pkg=jdk-$V.pkg"; do
  grep -qxF "$kv" "$bi" || fail "$bi does not record $kv: $(cat "$bi")"
done
[ ! -e "$t/img/legal/TRADEMARKS.txt" ] && [ ! -e "$t/img/java-runs" ] || fail "package-pkg changed the image"

expand "$pkg"
check_pkg
run_postinstall "$pkg" || fail "postinstall failed: $(cat "$t/post.out")"
[ "$(cat "$t/root$prefix/bin/java-runs")" = "-Xshare:dump" ] || fail "the postinstall ran java as '$(cat "$t/root$prefix/bin/java-runs" 2>/dev/null)', not once with -Xshare:dump"
grep -q "^$short: wrote the default CDS archive" "$t/post.out" || fail "the postinstall did not log the CDS archive: $(cat "$t/post.out")"
for b in java-25 javac-25; do
  [ -L "$t/root/usr/local/mavergreen/bin/$b" ] || fail "the farm does not export $b: $(ls "$t/root/usr/local/mavergreen/bin")"
done
: > "$t/root$prefix/bin/fail-dump"
run_postinstall "$pkg" || fail "postinstall failed when -Xshare:dump did: $(cat "$t/post.out")"
grep -q "^$short: WARNING: bin/java -Xshare:dump failed (exit 1)" "$t/post.out" \
  || fail "a failed -Xshare:dump is not logged: $(cat "$t/post.out")"
grep -q "Error occurred during initialization of VM" "$t/post.out" || fail "the log does not carry java's own error: $(cat "$t/post.out")"
mkdir -p "$t/root/$jdkdir/Contents/MacOS"; : > "$t/root/$jdkdir/Contents/MacOS/stale"
PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$t/scripts/preinstall" "$pkg" / "$t/root" > "$t/pre.out" 2>&1 \
  || fail "preinstall failed over an installed version: $(cat "$t/pre.out")"
[ ! -e "$t/root/$jdkdir" ] || fail "an upgrade's preinstall left the installed .jdk bundle: $(find "$t/root/$jdkdir")"
echo "PASS tiny image: base then $id, x86_64, the 10.9.5 floor; the payload is $prefix, the .jdk bundle and the updater; the manifest, the .jdk's Info.plist, Home and libjli link, the legend, java-25 and javac-25; build-info; CDS written by the postinstall, and its failure logged, not fatal; an upgrade clears the installed .jdk whole"

if [ "${JDK_PACKAGE_REAL:-}" != 1 ]; then
  echo "PASS: package (ran: tiny image; not run here: the real image, which needs JDK_PACKAGE_REAL=1)"
  exit 0
fi
unset JDK_IMAGE JDK_BUILD_INFO
app="${JDK_UPDATER_APP:-}"
if [ -z "$app" ]; then
  app="$t/real-upd/$short-updater.app"
  sh "$MAVERICKS_ROOT/build/build-updater.sh" --out "$app" > "$t/o" 2>&1 || fail "build-updater failed: $(cat "$t/o")"
fi
V="$("$PB" -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
mkdir -p "$t/dist"
sh "$package" --updater-app "$app" --version "$V" --out "$t/dist" > "$t/o" 2>&1 \
  || fail "package-pkg failed on the real image: $(cat "$t/o")"
pkg="$t/dist/jdk-$V.pkg"
expand "$pkg"
check_pkg
[ -f "$t/root$prefix/lib/server/libjvm.dylib" ] || fail "the real payload has no lib/server/libjvm.dylib"
sh "$SHIPYARD_SCRIPTS/stand-in-feeds.sh" "$t/dist" "$V" > "$t/o" 2>&1 || fail "stand-in-feeds failed: $(cat "$t/o")"
facts="$(sh "$SHIPYARD_SCRIPTS/artifact-facts.sh" "$t/dist" "$V" "$MAVERICKS_ROOT")" || fail "artifact-facts failed"
printf '%s\n' "$facts" | sh "$SHIPYARD_SCRIPTS/check-artifact-conformance.sh" > "$t/o" 2>&1 \
  || fail "conformance: $(cat "$t/o")"
echo "PASS real image: the same, and conformance ($(tail -1 "$t/o"))"
echo "PASS: package (ran: tiny image, real image)"
