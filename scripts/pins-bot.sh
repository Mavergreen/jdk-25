#!/bin/sh
# platform: host-agnostic
#   usage: sh scripts/pins-bot.sh moved <base-ref>
#          sh scripts/pins-bot.sh values
#          sh scripts/pins-bot.sh apply <KEY=VALUE>...
#          sh scripts/pins-bot.sh fill <base-ref>
#          What .github/workflows/pins-bot.yml decides and writes when it fills a JDK bump's pins on
#          Renovate's branch. Renovate moves GA alone (a jdk25u -ga tag); scripts/resolve-ga.sh finds
#          the REF and DIGEST it names, scripts/pin-source-tarballs.sh computes and checks the
#          tarball's TARBALL_SHA256, and scripts/pin-jtreg.sh moves components/jtreg/version to the
#          jtreg that source's own CI runs (ruling R48), after which scripts/pin-jtreg-deps.sh writes
#          that jtreg's build dependencies, components/jtreg/deps.
#          moved   exit 0, printing them, when components/jdk/version's source pin lines (GA, REF, DIGEST,
#                  TARBALL_SHA256) differ from those of the commit where this branch left <base-ref>; else 1;
#                  2 when git cannot tell (no merge base, a failed diff), never 1.
#          values  prints the filled pins as REF=<tag> DIGEST=<commit> TARBALL_SHA256=<sha256>
#                  JTREG_TAG=jtreg-<version> JTREG_SHA256=<sha256> JTREG_DEPS=<components/jtreg/deps, base64
#                  on one line>; refuses a REF that is not a jdk-25 build tag, a DIGEST that is not 40 hex
#                  digits, a SHA-256 that is not 64, a jtreg TAG that is not jtreg-N[.N...]+N, and a deps
#                  file that is not deps_ok's shape.
#          apply   writes those pins (one to six, each key once) into components/jdk/version,
#                  components/jtreg/version and components/jtreg/deps, and nothing else; refuses another
#                  key, a repeated one, a value of the wrong shape, or a JTREG_DEPS whose TAG line is not the
#                  jtreg pin it is applied with, before writing anything; prints "changed" or "unchanged".
#          fill    the pins job's whole decision: exit 0 printing nothing when no source pin moved (moved),
#                  or when resolve-ga.sh, pin-source-tarballs.sh and pin-jtreg.sh --check all exit 0
#                  (current); each one that exits 3 (stale) runs its write, in that order (pin-jtreg.sh
#                  reads the DIGEST the first writes), a pin-jtreg.sh write is followed by
#                  pin-jtreg-deps.sh's, and then the values are printed. Any other --check status (1 is an error, never "stale"), a failed write,
#                  or a failed moved, exits 1 having printed nothing; only a status-3 --check ever leads to
#                  its write. Progress goes to stderr: stdout is the values or nothing.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PINS="$HERE/components/jdk/version"
JPINS="$HERE/components/jtreg/version"
JDEPS="$HERE/components/jtreg/deps"
KEYS="REF DIGEST TARBALL_SHA256 JTREG_TAG JTREG_SHA256 JTREG_DEPS"
hexn() { case "$2" in *[!0-9a-f]*|'') return 1 ;; esac; [ "${#2}" -eq "$1" ]; }
shape() {  # shape <KEY> <VALUE>: the value has its key's shape
  case "$1" in
    REF) case "$2" in jdk-25.*+*) : ;; *) return 1 ;; esac
         case "$2" in *[!0-9a-z.+-]*) return 1 ;; esac ;;
    DIGEST) hexn 40 "$2" ;;
    TARBALL_SHA256|JTREG_SHA256) hexn 64 "$2" ;;
    JTREG_TAG) printf '%s\n' "$2" | grep -xE 'jtreg-[0-9]+(\.[0-9]+)*\+[0-9]+' > /dev/null ;;
    JTREG_DEPS) case "$2" in *[!A-Za-z0-9+/=]*|'') return 1 ;; esac ;;
    *) return 1 ;;
  esac
}
where() {  # where <KEY>: the pin file and line key that hold it
  case "$1" in
    JTREG_TAG) echo "$JPINS TAG" ;;
    JTREG_SHA256) echo "$JPINS SHA256" ;;
    *) echo "$PINS $1" ;;
  esac
}
# spec: scripts/pin-jtreg-deps.sh -- its output is TAG=<tag>, then one line per file jtreg's build
#       downloads, <path> <SHA-256> <URL>..., each path once, every URL https on a host its formulas use;
#       the push job writes these lines with a token that can push, so nothing else may reach it
deps_ok() {  # deps_ok <file> <jtreg tag>
  awk -v tag="$2" '
    NR == 1 { if ($0 != "TAG=" tag) bad = "its TAG line is not TAG=" tag; next }
    {
      if (NF < 3) { bad = "line " NR " is not <path> <sha256> <url>..."; next }
      if ($1 ~ /^apache-ant-[0-9.]+-bin\.zip$/) k = "ant"
      else if ($1 == "jtharness/source.zip" || $1 == "asmtools/source.zip" || $1 == "testng-license/LICENSE.txt") k = $1
      else if ($1 ~ /^junit\/junit-platform-console-standalone-[0-9.]+\.jar$/) k = "junit"
      else if ($1 ~ /^testng\/testng-[0-9.]+\.jar$/) k = "testng"
      else if ($1 ~ /^jcommander\/jcommander-[0-9.]+\.jar$/) k = "jcommander"
      else if ($1 ~ /^guice\/guice-[0-9.]+\.jar$/) k = "guice"
      else { bad = "line " NR "'"'"'s path " $1 " is none jtreg downloads"; next }
      if (seen[k]++) bad = "line " NR " repeats " k
      if ($2 !~ /^[0-9a-f]+$/ || length($2) != 64) bad = "line " NR "'"'"'s SHA-256 is not 64 hex digits"
      for (i = 3; i <= NF; i++)
        if ($i !~ /^https:\/\/(archive\.apache\.org|repo\.huaweicloud\.com|git\.openjdk\.org|repo1\.maven\.org|raw\.githubusercontent\.com)\/[A-Za-z0-9._\/+-]+$/ || $i ~ /\.\./)
          bad = "line " NR "'"'"'s URL " $i " is not one jtreg'"'"'s build uses"
    }
    END {
      if (NR == 0) bad = "it is empty"
      n = split("ant jtharness/source.zip asmtools/source.zip junit testng testng-license/LICENSE.txt jcommander guice", want, " ")
      for (i = 1; i <= n; i++) if (!(want[i] in seen)) bad = "it has no " want[i]
      if (bad != "") { print bad > "/dev/stderr"; exit 1 }
    }' "$1"
}
case "${1:-}" in
  moved)
    [ $# -eq 2 ] || { echo "usage: pins-bot.sh moved <base-ref>" >&2; exit 2; }
    base="$(git -C "$HERE" merge-base "$2" HEAD)" || { echo "pins-bot: no merge base with $2" >&2; exit 2; }
    d="$(git -C "$HERE" diff "$base" HEAD -- components/jdk/version)" || { echo "pins-bot: git diff $base HEAD -- components/jdk/version failed" >&2; exit 2; }
    lines="$(printf '%s\n' "$d" | grep -E '^[-+](GA|REF|DIGEST|TARBALL_SHA256)=' || :)"
    [ -n "$lines" ] || exit 1
    printf '%s\n' "$lines" ;;
  values)
    [ $# -eq 1 ] || { echo "usage: pins-bot.sh values" >&2; exit 2; }
    out=""
    for k in REF DIGEST TARBALL_SHA256 JTREG_TAG JTREG_SHA256; do
      set -- $(where "$k")
      v="$(sed -n "s/^$2=//p" "$1")"
      shape "$k" "$v" || { echo "pins-bot: components/${1#"$HERE/components/"}'s $2 is '$v', which is not a $k" >&2; exit 1; }
      out="$out${out:+ }$k=$v"
    done
    jtag="$(sed -n 's/^TAG=//p' "$JPINS")"
    deps_ok "$JDEPS" "$jtag" 2> "${TMPDIR:-/tmp}/pins-bot-deps.$$" || {
      echo "pins-bot: components/jtreg/deps is not $jtag's build dependencies: $(cat "${TMPDIR:-/tmp}/pins-bot-deps.$$")" >&2
      rm -f "${TMPDIR:-/tmp}/pins-bot-deps.$$"; exit 1; }
    rm -f "${TMPDIR:-/tmp}/pins-bot-deps.$$"
    echo "$out JTREG_DEPS=$(base64 < "$JDEPS" | tr -d '\n')" ;;
  apply)
    shift; [ $# -ge 1 ] && [ $# -le 6 ] || { echo "usage: pins-bot.sh apply <KEY=VALUE>... (one to six of $KEYS)" >&2; exit 2; }
    seen=" "; deps=""
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      case " $KEYS " in *" $k "*) ;; *) echo "pins-bot: '$k' is not a source pin ($KEYS)" >&2; exit 1 ;; esac
      case "$seen" in *" $k "*) echo "pins-bot: $k is given more than once" >&2; exit 1 ;; esac
      seen="$seen$k "
      shape "$k" "$v" || { echo "pins-bot: $k's value '$v' is not a $k" >&2; exit 1; }
      if [ "$k" = JTREG_DEPS ]; then deps="$v"; continue; fi
      f="$(where "$k")"
      grep -q "^${f#* }=" "${f% *}" || { echo "pins-bot: ${f% *} has no ${f#* } line" >&2; exit 1; }
    done
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/pins-bot.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    cp "$PINS" "$tmp/jdk"; cp "$JPINS" "$tmp/jtreg"; cp "$JDEPS" "$tmp/deps"
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      [ "$k" != JTREG_DEPS ] || continue
      f="$(where "$k")"; case "${f% *}" in "$PINS") t="$tmp/jdk" ;; *) t="$tmp/jtreg" ;; esac
      awk -v k="${f#* }" -v v="$v" 'index($0, k "=") == 1 { $0 = k "=" v } { print }' "$t" > "$t.n" && mv "$t.n" "$t"
    done
    jtag="$(sed -n 's/^TAG=//p' "$tmp/jtreg")"
    if [ -n "$deps" ]; then
      printf '%s' "$deps" | base64 --decode > "$tmp/deps" 2> /dev/null || { echo "pins-bot: JTREG_DEPS is not base64" >&2; exit 1; }
      deps_ok "$tmp/deps" "$jtag" 2> "$tmp/why" || { echo "pins-bot: JTREG_DEPS is not $jtag's build dependencies: $(cat "$tmp/why")" >&2; exit 1; }
    fi
    # spec: PORT.md ruling R48 -- the jtreg pin and its deps move together, so neither is written alone
    [ "$(sed -n 1p "$tmp/deps")" = "TAG=$jtag" ] \
      || { echo "pins-bot: components/jtreg/deps would be for $(sed -n 's/^TAG=//p;q' "$tmp/deps"), but the jtreg pin $jtag: give JTREG_DEPS with it" >&2; exit 1; }
    changed=0
    for pair in "jdk:$PINS" "jtreg:$JPINS" "deps:$JDEPS"; do
      cmp -s "$tmp/${pair%%:*}" "${pair#*:}" || { cat "$tmp/${pair%%:*}" > "${pair#*:}"; changed=1; }
    done
    if [ "$changed" = 1 ]; then echo changed; else echo unchanged; fi ;;
  fill)
    [ $# -eq 2 ] || { echo "usage: pins-bot.sh fill <base-ref>" >&2; exit 2; }
    rc=0; sh "$HERE/scripts/pins-bot.sh" moved "$2" >&2 || rc=$?
    case "$rc" in
      0) ;;
      1) echo "pins-bot: no source pin moved: nothing to do" >&2; exit 0 ;;
      *) echo "pins-bot: could not tell whether a source pin moved (moved exited $rc)" >&2; exit 1 ;;
    esac
    wrote=0
    for step in resolve-ga pin-source-tarballs pin-jtreg; do
      rc=0; sh "$HERE/scripts/$step.sh" --check >&2 || rc=$?
      case "$rc" in
        0) echo "pins-bot: $step.sh says its pins are current" >&2 ;;
        3) echo "pins-bot: $step.sh says its pins are stale: writing them" >&2
           sh "$HERE/scripts/$step.sh" >&2 || { echo "pins-bot: $step.sh could not write its pins" >&2; exit 1; }
           wrote=1
           if [ "$step" = pin-jtreg ]; then
             sh "$HERE/scripts/pin-jtreg-deps.sh" >&2 || { echo "pins-bot: pin-jtreg-deps.sh could not write the moved jtreg's build dependencies" >&2; exit 1; }
           fi ;;
        *) echo "pins-bot: $step.sh --check exited $rc, an error rather than a stale pin: writing nothing" >&2; exit 1 ;;
      esac
    done
    [ "$wrote" = 1 ] || { echo "pins-bot: every pin is current: nothing to do" >&2; exit 0; }
    sh "$HERE/scripts/pins-bot.sh" values ;;
  *) echo "usage: pins-bot.sh moved <base-ref> | values | apply <KEY=VALUE>... | fill <base-ref>" >&2; exit 2 ;;
esac
