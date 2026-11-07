#!/bin/sh
# platform: macOS-only -- shipyard's compat guard reads each image's Mach-O with otool, nm and lipo
#   usage: sh build/compare-builds.sh CROSS_IMAGE NATIVE_IMAGE
#          Compares a cross-built JDK image with a native Mac OS X 10.9 one. Each is a JDK home with its
#          build-info.txt beside it, as build/build-jdk.sh leaves $(jdk_build_root)/image and CI's image
#          artifact unpacks. Exits 0 iff:
#            both build-info.txt agree on every key both have, except what PORT.md ruling R55 excuses;
#            both images pass the compat guard (jdk_compat_guard), Mach-O inside archives included;
#            the sorted lists of their files, and of each archive's entries (every jmod, jar and zip), are
#            the same;
#            every file and archive entry has the same bytes, except Mach-O, and what records Mach-O
#            hashes when a Mach-O differs (R55: lib/modules, and a jmod's module-info.class holding
#            ModuleHashes).
#          An archive is compared by its entries, never its own bytes: its entries carry configure's
#          time. A jmod's entries are unpacked (its Mach-O are guarded); a jar's or zip's are compared
#          by length and CRC-32. A difference is reported as "Mach-O differs: PATH", "excused (records Mach-O hashes):
#          PATH" or "differs (not Mach-O): PATH", an archive entry as ARCHIVE!ENTRY. A key only one
#          build-info.txt has is reported, not compared.
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
  (cd "$_i" && find . -type f -exec file {} +) | sed 's|^\./||' > "$T/$_n.types"
  # platform: file(1) names a jar "Java archive" or "Zip archive" and a jmod "Java jmod", or on 10.9 only
  #           "data", so a jmod is also known by its name
  { grep -E ': +(Zip archive|Java archive|Java jmod)' "$T/$_n.types" | sed 's|: .*||'
    sed -n 's|^\(.*\.jmod\): .*|\1|p' "$T/$_n.types"; } | sort -u > "$T/$_n.zips"
  sed -n 's|^\(.*\): *Mach-O.*|\1|p' "$T/$_n.types" > "$T/$_n.macho"
  sed "s|^|$_i/|" "$T/$_n.macho" > "$T/$_n.guard"
  (cd "$_i" && find . -type f -exec shasum -a 256 {} +) | sed 's|  \./|  |' \
    | awk 'NR == FNR { z[$0] = 1; next } { p = $0; sub(/^[^ ]*  /, "", p); if (p in z) print "archive  " p; else print }' \
      "$T/$_n.zips" - > "$T/$_n.sums"
  (cd "$_i" && find . -type l | while IFS= read -r _l; do printf 'link:%s  %s\n' "$(readlink "$_l")" "${_l#./}"; done) >> "$T/$_n.sums"
  while IFS= read -r _z; do
    case "$_z" in
      *.jmod) ;;
      *)
        # platform: a jar or zip is compared by unzip -v's listing (each entry's length and CRC-32), not
        #           unpacked: lib/security/public_suffix_list.dat's 1452 entries have IDN names, and
        #           unpacked onto APFS only 1295 remain, unzip exiting 50
        _rc=0; unzip -v "$_i/$_z" > "$T/$_n.v" 2>/dev/null || _rc=$?
        [ "$_rc" -le 1 ] || { echo "compare-builds: unzip -v exited $_rc on $_i/$_z" >&2; exit 2; }
        awk -v z="$_z" 'NF >= 8 && length($7) == 8 && $7 ~ /^[0-9a-f]+$/ && $1 ~ /^[0-9]+$/ {
            e = $0; for (k = 1; k <= 7; k++) sub(/^ *[^ ]+/, "", e); sub(/^ +/, "", e)
            if (e !~ /\/$/) print "crc:" $7 ":" $1 "  " z "!" e }' "$T/$_n.v" >> "$T/$_n.sums"
        continue ;;
    esac
    _d="$T/$_n.x/$_z"; mkdir -p "$_d"
    # platform: a jmod is a zip behind a 4-byte header, which unzip reads past, exiting 1 for that
    #           header's warning, 2 and up on a real failure.
    _rc=0; unzip -qo "$_i/$_z" -d "$_d" > /dev/null 2>&1 || _rc=$?
    [ "$_rc" -le 1 ] || { echo "compare-builds: unzip exited $_rc on $_i/$_z" >&2; exit 2; }
    (cd "$_d" && find . -type f -exec shasum -a 256 {} +) | sed "s|  \./|  $_z!|" >> "$T/$_n.sums"
    (cd "$_d" && find . -type f -exec file {} +) | sed -n 's|^\./\(.*\): *Mach-O.*|\1|p' > "$T/$_n.zm"
    sed "s|^|$_z!|" "$T/$_n.zm" >> "$T/$_n.macho"
    sed "s|^|$_d/|" "$T/$_n.zm" >> "$T/$_n.guard"
  done < "$T/$_n.zips"
  # platform: unzip -v prints each non-ASCII byte of an entry's name as "?", so public_suffix_list.dat's
  #           IDN names collide; a path's hashes are compared as one sorted list
  awk '{ h = $1; p = $0; sub(/^[^ ]*  /, "", p); print p "\t" h }' "$T/$_n.sums" | sort \
    | awk -F '\t' '{ if (NR > 1 && $1 == last) acc = acc "," $2; else { if (NR > 1) print acc "  " last; acc = $2; last = $1 } }
                   END { if (NR) print acc "  " last }' > "$T/$_n.sums2"
  mv "$T/$_n.sums2" "$T/$_n.sums"
  sed 's/^[^ ]*  //' "$T/$_n.sums" | sort > "$T/$_n.paths"
  sort -o "$T/$_n.macho" "$T/$_n.macho"
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

join -1 2 -2 2 -o 0,1.1,2.1 "$T/cross.sums" "$T/native.sums" | while read -r p c n; do
  [ "$c" = "$n" ] && continue
  if grep -qxF "$p" "$T/cross.macho"; then echo "macho $p"; else echo "other $p"; fi
done > "$T/diffs"
sed -n 's/^macho //p' "$T/diffs" | while IFS= read -r p; do say "Mach-O differs: $p"; done
machodiff=no; ! grep -q '^macho ' "$T/diffs" || machodiff=yes
# spec: PORT.md ruling R55 -- only what records the Mach-O's hashes may differ with them: lib/modules, and
#       a jmod's module-info.class that holds ModuleHashes on both sides
hashes() {
  [ "$machodiff" = yes ] || return 1
  case "$1" in
    lib/modules) return 0 ;;
    *.jmod!classes/module-info.class)
      grep -q ModuleHashes "$T/cross.x/${1%%!*}/${1#*!}" && grep -q ModuleHashes "$T/native.x/${1%%!*}/${1#*!}" ;;
    *) return 1 ;;
  esac
}
sed -n 's/^other //p' "$T/diffs" | while IFS= read -r p; do
  if hashes "$p"; then say "excused (records Mach-O hashes): $p"; else say "differs (not Mach-O): $p"; echo x >> "$T/bytebad"; fi
done
[ ! -s "$T/bytebad" ] || bad=1

if [ "$bad" = 0 ]; then say "PASS: the native image agrees with the cross image"; exit 0; fi
say "FAIL: the native image differs from the cross image"; exit 1
