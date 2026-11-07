#!/bin/sh
# platform: macOS-only -- stevedore and productbuild, through shipyard's build_component_pkg.sh and set_install_floor.sh
#   usage: build/package-pkg.sh --updater-app APP --version V [--out DIR]
#          Packages the image build/build-jdk.sh left in $(jdk_build_root)/image, or JDK_IMAGE, with
#          its build-info.txt ($(jdk_build_root)/build-info.txt, or JDK_BUILD_INFO), and APP
#          (build/build-updater.sh) as DIR/jdk-V.pkg (DIR defaults to dist/): the dev.mavergreen.base
#          component, then jdk25's, with the 10.9.5 floor and an x86_64 Installer host. The image goes to
#          /usr/local/mavergreen/jdk25 with the trademark legend in legal/TRADEMARKS.txt, and
#          /Library/Java/JavaVirtualMachines/mavergreen-jdk25.jdk holds only its Info.plist, a Home link
#          to that prefix, and Contents/MacOS/libjli.dylib linked to Home's lib/libjli.dylib. The postinstall writes the default CDS archive with bin/java
#          -Xshare:dump; a failure is logged and does not fail the install. V is the image's
#          JAVA_VERSION with its -mavericks.N, and the updater's version. Also writes
#          DIR/build-info-jdk25.txt: build-info.txt plus what packaging adds. Nothing is rebuilt, and
#          the image is not changed.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
. "$here/toolchain.sh"

usage() { echo "usage: build/package-pkg.sh --updater-app APP --version V [--out DIR]" >&2; exit 2; }
die() { echo "package-pkg: $*" >&2; exit 1; }
app=""; V=""; out="$MAVERICKS_ROOT/dist"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --updater-app) [ "$#" -ge 2 ] || usage; app=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] || usage; V=$2; shift 2 ;;
    --out) [ "$#" -ge 2 ] || usage; out=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$app" ] && [ -n "$V" ] || usage
short=jdk25
line=25
prefix="/usr/local/mavergreen/$short"
jdkdir=Library/Java/JavaVirtualMachines/mavergreen-jdk25.jdk
img="${JDK_IMAGE:-$(jdk_build_root)/image}"
info="${JDK_BUILD_INFO:-$(jdk_build_root)/build-info.txt}"
[ -x "$img/bin/java" ] && [ -f "$img/release" ] && [ -f "$img/lib/libjli.dylib" ] \
  || die "$img is not a JDK image (no bin/java, release or lib/libjli.dylib); run build/build-jdk.sh first"
[ -f "$info" ] || die "no $info beside the image; run build/build-jdk.sh first"
id="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" identifier "$short")" || die "$short is not in shipyard's registry"

jv="$(sed -n 's/^JAVA_VERSION="\(.*\)"$/\1/p' "$img/release")"
jrv="$(sed -n 's/^JAVA_RUNTIME_VERSION="\(.*\)"$/\1/p' "$img/release")"
case "$V" in
  "$jv"-mavericks.[1-9]*) ;;
  *) die "--version $V is not the image's JAVA_VERSION ${jv:-(unknown)} with a -mavericks.N" ;;
esac
up="$(sh "$MAVERICKS_ROOT/build/derive-upstream-version.sh" --print)"
[ "$jv" = "$up" ] || die "the image is JDK ${jv:-(unknown)}, but UPSTREAM_VERSION is $up; rebuild it with build/build-jdk.sh"
case "$jrv" in
  *"-${V#"$jv"-}") ;;
  *) die "--version $V is not the image's build: its JAVA_RUNTIME_VERSION is ${jrv:-(unknown)}" ;;
esac
updv="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null)" \
  || die "$app has no Contents/Info.plist with a CFBundleShortVersionString"
[ "$updv" = "$V" ] || die "$app is version $updv, not $V"

mkdir -p "$out" "$(jdk_build_root)"
case "$out" in /*) ;; *) out="$(cd "$out" && pwd)" ;; esac
work="$(mktemp -d "$(jdk_build_root)/package.XXXXXX")"
trap 'rm -rf "$work"' EXIT
root="$work/root"; dest="$root$prefix"
mkdir -p "${dest%/*}" "$root/$jdkdir/Contents" "$work/scripts" "$work/resources" "$work/component"
COPYFILE_DISABLE=1 cp -Rp "$img" "$dest"
# spec: PORT.md ruling R51 -- the verbatim legend
printf '%s\n' "Java and OpenJDK are trademarks or registered trademarks of Oracle and/or its affiliates." \
  > "$dest/legal/TRADEMARKS.txt"
sed -e "s/@UPSTREAM@/$jv/g" -e "s/@VERSION@/$V/g" "$here/jdk-bundle-Info.plist.in" > "$root/$jdkdir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :JavaVM:JVMVersion' "$root/$jdkdir/Contents/Info.plist" > /dev/null \
  || die "the .jdk bundle's Info.plist is not a plist"
# platform: /usr/libexec/java_home on 10.9 finds a JDK only as a bundle in JavaVirtualMachines, and
#           resolves its Contents/Home; the image stays in the family prefix.
ln -s "$prefix" "$root/$jdkdir/Contents/Home"
# platform: PORT.md ruling R44 -- 10.9's java_home and the
#           /usr/bin stubs list a JDK bundle only when its CFBundleExecutable names a Contents/MacOS
#           file; libjli.dylib, linked to Home's, is the one Oracle's bundles name.
mkdir -p "$root/$jdkdir/Contents/MacOS"
ln -s ../Home/lib/libjli.dylib "$root/$jdkdir/Contents/MacOS/libjli.dylib"
find "$root" -name '._*' -exec rm -f {} +

# spec: PORT.md ruling R28 -- the image ships no CDS archive
#       (a cross-build cannot run the x86_64 java that writes it), so the installing Mac writes it;
#       a failure leaves a JDK that works without one, so it is logged, never fatal.
cat > "$work/postinstall-hook" <<EOF
_cds_out="\$("\$ROOT$prefix/bin/java" -Xshare:dump 2>&1)" && _cds_rc=0 || _cds_rc=\$?
if [ "\$_cds_rc" -eq 0 ]; then
  echo "$short: wrote the default CDS archive (bin/java -Xshare:dump)"
else
  echo "$short: WARNING: bin/java -Xshare:dump failed (exit \$_cds_rc); the JDK works, but starts without the default CDS archive:" >&2
  printf '%s\n' "\$_cds_out" | tail -n 20 >&2
fi
:
EOF
sh "$SHIPYARD_SCRIPTS/stage_product.sh" --stage "$root" --product "$short" --name "JDK $line" \
  --group jdk --line "$line" --version "$V" --updater-app "$app" --scripts-out "$work/scripts" \
  --postinstall-hook "$work/postinstall-hook" >&2
find "$root" -name '._*' -exec rm -f {} +

cp "$MAVERICKS_ROOT/scripts/resources/Welcome.html" "$work/resources/"
cp "$dest/legal/java.base/LICENSE" "$work/resources/LICENSE.txt"
comp="$work/component/$short.pkg"
sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" --root "$root" --identifier "$id" --version "$V" \
  --install-location / --scripts "$work/scripts" --out "$comp" >&2
sh "$SHIPYARD_SCRIPTS/set_install_floor.sh" --identifier "$id" --title "JDK $line for Mavericks" \
  --component "$comp" --out "$work/product.pkg" --resources "$work/resources" --welcome Welcome.html \
  --license LICENSE.txt --host-arch x86_64 --min-os 10.9.5 --require-scripts >&2

set --
while IFS= read -r kv || [ -n "$kv" ]; do
  case "$kv" in *=*) set -- "$@" "$kv" ;; esac
done < "$info"
sh "$SHIPYARD_SCRIPTS/build-info.sh" "$work/build-info-jdk25.txt" "$@" \
  variant="$short" arch=x86_64 prefix="$prefix" identifier="$id" version="$V" pkg="jdk-$V.pkg"
pkg="$out/jdk-$V.pkg"
mv "$work/product.pkg" "$pkg"
mv "$work/build-info-jdk25.txt" "$out/build-info-jdk25.txt"
echo "package-pkg: $pkg and $out/build-info-jdk25.txt" >&2
