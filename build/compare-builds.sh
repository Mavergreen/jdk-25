#!/bin/sh
# platform: macOS-only -- shipyard's compat guard reads each image's Mach-O with otool, nm and lipo
#   usage: sh build/compare-builds.sh CROSS_IMAGE NATIVE_IMAGE
#          Compares a cross-built JDK image with a native Mac OS X 10.9 one. Each is a JDK home with its
#          build-info.txt beside it, as build/build-jdk.sh leaves $(jdk_build_root)/image and CI's image
#          artifact unpacks. Exits 0 iff:
#            both build-info.txt agree on every key both have, except what PORT.md ruling R55 excuses;
#            both images pass the compat guard (jdk_compat_guard), jmods' Mach-O included;
#            the sorted lists of their files, and of each jmod's entries, are the same.
#          Mach-O bytes may differ and are reported as "Mach-O differs: PATH" (a jmod's entry as
#          jmods/NAME.jmod!ENTRY), and so are other files' bytes, as "differs (not Mach-O): PATH": a
#          jmod's module-info records hashes of the jmods its natives are in, so a Mach-O difference
#          reaches them. A key only one build-info.txt has is reported, not compared.
#          Exits 1 on a difference, 2 on a usage error or a missing image or build-info.txt.
# spec: PORT.md ruling R55
set -eu
LC_ALL=C; export LC_ALL
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
usage() { echo "usage: sh build/compare-builds.sh CROSS_IMAGE NATIVE_IMAGE" >&2; exit 2; }
say() { echo "compare-builds: $*"; }
[ "$#" = 2 ] || usage
for i in "$1" "$2"; do
  [ -d "$i" ] || { echo "compare-builds: no image at $i" >&2; exit 2; }
  [ -f "$(dirname "$i")/build-info.txt" ] || { echo "compare-builds: no build-info.txt beside $i" >&2; exit 2; }
done
. "$here/toolchain.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/compare-builds.XXXXXX")"
trap 'rm -rf "$T"' EXIT
bad=0

side() {
  _n=$1; _i="$(cd "$2" && pwd)"
  grep '=' "$(dirname "$_i")/build-info.txt" | sort > "$T/$_n.info"
  mkdir -p "$T/$_n.jmods"
  for _m in "$_i"/jmods/*.jmod; do
    [ -f "$_m" ] || continue
    _d="$T/$_n.jmods/$(basename "$_m")"; mkdir -p "$_d"
    # platform: a jmod is a zip behind a 4-byte header, which unzip reads past, exiting 1 for that
    #           header's warning, 2 and up on a real failure.
    _rc=0; unzip -qo "$_m" -d "$_d" > /dev/null 2>&1 || _rc=$?
    [ "$_rc" -le 1 ] || { echo "compare-builds: unzip exited $_rc on $_m" >&2; exit 2; }
  done
  { (cd "$_i" && find . -type f -exec shasum -a 256 {} + | sed 's|  \./|  |')
    (cd "$T/$_n.jmods" && find . -type f -exec shasum -a 256 {} + | sed 's|  \./\([^/]*\)/|  jmods/\1!|')
    (cd "$_i" && find . -type l | while IFS= read -r _l; do printf 'link:%s  %s\n' "$(readlink "$_l")" "${_l#./}"; done)
  } | sort -k2 > "$T/$_n.sums"
  sed 's/^[^ ]*  //' "$T/$_n.sums" | sort > "$T/$_n.paths"
  (cd "$_i" && find . -type f -exec file {} + | sed -n 's|^\./\(.*\): *Mach-O.*|\1|p'; \
   cd "$T/$_n.jmods" && find . -type f -exec file {} + | sed -n 's|^\./\([^/]*\)/\(.*\): *Mach-O.*|jmods/\1!\2|p') \
    | sort > "$T/$_n.macho"
  (cd "$_i" && find . -type f -exec file {} + | sed -n "s|^\(.*\): *Mach-O.*|$_i/\1|p"; \
   cd "$T/$_n.jmods" && find . -type f -exec file {} + | sed -n "s|^\(.*\): *Mach-O.*|$T/$_n.jmods/\1|p") \
    | sed 's|/\./|/|' > "$T/$_n.guard"
}
side cross "$1"
side native "$2"

val() { sed -n "s/^$2=//p" "$T/$1.info"; }
cut -d= -f1 "$T/cross.info" | sort -u > "$T/cross.keys"
cut -d= -f1 "$T/native.info" | sort -u > "$T/native.keys"
nopandoc=no
for k in $(comm -12 "$T/cross.keys" "$T/native.keys"); do
  c="$(val cross "$k")"; n="$(val native "$k")"
  [ "$c" = "$n" ] && continue
  case "$k" in
    # spec: PORT.md ruling R55 -- where each was built, and with which boot JDK, differ by design
    host|bootjdk) say "excused: $k: $c (cross) vs $n (native)" ;;
    # spec: PORT.md ruling R19 -- no pinned pandoc runs on Mac OS X 10.9, so that build has no man pages
    pandoc)
      if [ "$c" = none ] || [ "$n" = none ]; then nopandoc=yes; say "excused: pandoc: $c (cross) vs $n (native)"
      else say "build-info: pandoc differs: $c (cross) vs $n (native)"; bad=1; fi ;;
    *) say "build-info: $k differs: $c (cross) vs $n (native)"; bad=1 ;;
  esac
done
for k in $(comm -23 "$T/cross.keys" "$T/native.keys"); do say "build-info: only cross has $k (not compared)"; done
for k in $(comm -13 "$T/cross.keys" "$T/native.keys"); do say "build-info: only native has $k (not compared)"; done

for s in cross native; do
  [ -s "$T/$s.guard" ] || { say "no Mach-O in the $s image"; bad=1; continue; }
  # shellcheck disable=SC2046  # the paths are the images' and this script's temporary directory's
  if jdk_compat_guard $(cat "$T/$s.guard") > "$T/$s.guard.out" 2>&1; then
    say "compat guard: $s passes ($(wc -l < "$T/$s.guard" | tr -d ' ') Mach-O)"
  else
    sed 's/^/  /' "$T/$s.guard.out"; say "compat guard refuses $s"; bad=1
  fi
done

# spec: PORT.md ruling R55 -- with pandoc=none on a side, the man pages it could not make are excused
manpage() { case "$1" in man/*|jmods/*!man/*) [ "$nopandoc" = yes ] ;; *) return 1 ;; esac; }
comm -23 "$T/cross.paths" "$T/native.paths" | while IFS= read -r p; do
  if manpage "$p"; then say "excused (pandoc=none): $p"; else say "only in cross: $p"; echo x >> "$T/listbad"; fi
done
comm -13 "$T/cross.paths" "$T/native.paths" | while IFS= read -r p; do
  if manpage "$p"; then say "excused (pandoc=none): $p"; else say "only in native: $p"; echo x >> "$T/listbad"; fi
done
[ ! -s "$T/listbad" ] || bad=1

join -1 2 -2 2 -o 0,1.1,2.1 "$T/cross.sums" "$T/native.sums" 2>/dev/null | while read -r p c n; do
  [ "$c" = "$n" ] && continue
  if grep -qxF "$p" "$T/cross.macho"; then say "Mach-O differs: $p"; else say "differs (not Mach-O): $p"; fi
done

if [ "$bad" = 0 ]; then say "PASS: the native image agrees with the cross image"; exit 0; fi
say "FAIL: the native image differs from the cross image"; exit 1
