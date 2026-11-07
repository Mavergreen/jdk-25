#!/bin/sh
# platform: host-agnostic
#   usage: sh scripts/pins-bot.sh moved <base-ref>
#          sh scripts/pins-bot.sh values
#          sh scripts/pins-bot.sh apply <KEY=VALUE>...
#          sh scripts/pins-bot.sh fill <base-ref>
#          What .github/workflows/pins-bot.yml decides and writes when it fills a JDK bump's pins on
#          Renovate's branch. Renovate moves GA alone (a jdk25u -ga tag); scripts/resolve-ga.sh finds
#          the REF and DIGEST it names, and scripts/pin-source-tarballs.sh computes and checks the
#          tarball's TARBALL_SHA256.
#          moved   exit 0, printing them, when components/jdk/version's source pin lines (GA, REF, DIGEST,
#                  TARBALL_SHA256) differ from those of the commit where this branch left <base-ref>; else 1;
#                  2 when git cannot tell (no merge base, a failed diff), never 1.
#          values  prints the filled pins as REF=<tag> DIGEST=<commit> TARBALL_SHA256=<sha256>; refuses a
#                  REF that is not a jdk-25 build tag, a DIGEST that is not 40 hex digits, a TARBALL_SHA256
#                  that is not 64.
#          apply   writes those pins (one to three, each key once) into components/jdk/version and nothing
#                  else; refuses another key, a repeated one or a value of the wrong shape, before writing
#                  anything; prints "changed" or "unchanged".
#          fill    the pins job's whole decision: exit 0 printing nothing when no source pin moved (moved),
#                  or when resolve-ga.sh --check and pin-source-tarballs.sh --check both exit 0 (current);
#                  each one that exits 3 (stale) runs its write, REF and DIGEST first, and then the values
#                  are printed. Any other --check status (1 is an error, never "stale"), a failed write,
#                  or a failed moved, exits 1 having printed nothing; only a status-3 --check ever leads to
#                  its write. Progress goes to stderr: stdout is the values or nothing.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PINS="$HERE/components/jdk/version"
KEYS="REF DIGEST TARBALL_SHA256"
hexn() { case "$2" in *[!0-9a-f]*|'') return 1 ;; esac; [ "${#2}" -eq "$1" ]; }
shape() {  # shape <KEY> <VALUE>: the value has its key's shape
  case "$1" in
    REF) case "$2" in jdk-25.*+*) : ;; *) return 1 ;; esac
         case "$2" in *[!0-9a-z.+-]*) return 1 ;; esac ;;
    DIGEST) hexn 40 "$2" ;;
    TARBALL_SHA256) hexn 64 "$2" ;;
    *) return 1 ;;
  esac
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
    for k in $KEYS; do
      v="$(sed -n "s/^$k=//p" "$PINS")"
      shape "$k" "$v" || { echo "pins-bot: components/jdk/version's $k is '$v', which is not a $k" >&2; exit 1; }
      out="$out${out:+ }$k=$v"
    done
    echo "$out" ;;
  apply)
    shift; [ $# -ge 1 ] && [ $# -le 3 ] || { echo "usage: pins-bot.sh apply <KEY=VALUE>... (one to three of $KEYS)" >&2; exit 2; }
    seen=" "
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      case " $KEYS " in *" $k "*) ;; *) echo "pins-bot: '$k' is not a source pin ($KEYS)" >&2; exit 1 ;; esac
      case "$seen" in *" $k "*) echo "pins-bot: $k is given more than once" >&2; exit 1 ;; esac
      seen="$seen$k "
      shape "$k" "$v" || { echo "pins-bot: $k's value '$v' is not a $k" >&2; exit 1; }
      grep -q "^$k=" "$PINS" || { echo "pins-bot: components/jdk/version has no $k line" >&2; exit 1; }
    done
    tmp="$(mktemp "${TMPDIR:-/tmp}/pins-bot.XXXXXX")"
    cp "$PINS" "$tmp"
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      awk -v k="$k" -v v="$v" 'index($0, k "=") == 1 { $0 = k "=" v } { print }' "$tmp" > "$tmp.n" && mv "$tmp.n" "$tmp"
    done
    if cmp -s "$tmp" "$PINS"; then rm -f "$tmp"; echo unchanged; else cat "$tmp" > "$PINS"; rm -f "$tmp"; echo changed; fi ;;
  fill)
    [ $# -eq 2 ] || { echo "usage: pins-bot.sh fill <base-ref>" >&2; exit 2; }
    rc=0; sh "$HERE/scripts/pins-bot.sh" moved "$2" >&2 || rc=$?
    case "$rc" in
      0) ;;
      1) echo "pins-bot: no source pin moved: nothing to do" >&2; exit 0 ;;
      *) echo "pins-bot: could not tell whether a source pin moved (moved exited $rc)" >&2; exit 1 ;;
    esac
    wrote=0
    for step in resolve-ga pin-source-tarballs; do
      rc=0; sh "$HERE/scripts/$step.sh" --check >&2 || rc=$?
      case "$rc" in
        0) echo "pins-bot: $step.sh says its pins are current" >&2 ;;
        3) echo "pins-bot: $step.sh says its pins are stale: writing them" >&2
           sh "$HERE/scripts/$step.sh" >&2 || { echo "pins-bot: $step.sh could not write its pins" >&2; exit 1; }
           wrote=1 ;;
        *) echo "pins-bot: $step.sh --check exited $rc, an error rather than a stale pin: writing nothing" >&2; exit 1 ;;
      esac
    done
    [ "$wrote" = 1 ] || { echo "pins-bot: every pin is current: nothing to do" >&2; exit 0; }
    sh "$HERE/scripts/pins-bot.sh" values ;;
  *) echo "usage: pins-bot.sh moved <base-ref> | values | apply <KEY=VALUE>... | fill <base-ref>" >&2; exit 2 ;;
esac
