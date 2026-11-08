#!/bin/sh
# platform: macOS-only -- runs the product's JDK, a macOS build, and jtreg on it
#   usage: [JTREG_HOME=<jtreg>] [JTREG_SRC=<jdk source>] [JTREG_WORK=<dir>] [JTREG_CONC=<n>] [JTREG_ROOTS="hotspot jdk"]
#          [JTREG_NATIVEPATH=<test natives>]
#          sh tests/jtreg.sh <JDK_HOME> <known-failures-file>...
#          Runs a jtreg conformance subset of the pinned jdk25u source's own tests against <JDK_HOME>,
#          and passes only when every test that fails is one the known-failures files list and every
#          listed test ran. The files are read together: tests/known-failures/x86_64-10.9.txt is the
#          release gate's, for a clean single-NIC 10.9 like the mavericks-vm guest, and a host's own
#          overlay adds what fails only there, such as
#            sh tests/jtreg.sh JDK tests/known-failures/x86_64-10.9.txt tests/known-failures/x86_64-10.9-multihomed-host.txt
#          Each file is checked as one; a test listed in two of them is an error. A listed test that passed is printed as `stale: <id>`, which does not
#          fail the run: a fix arriving should not break the gate, but its line should go. One line per test:
#            <hotspot|jdk>:<test id>  # <reason>
#          where <test id> is the test's path under its root as jtreg reports it, with any #id suffix.
#          The subset, per root (each one jtreg run, with that root's ProblemList.txt excluded):
#            hotspot  tier1 without tier1_gc_gcbasher: tier1_common, tier1_compiler, tier1_gc_1,
#                     tier1_gc_2 (which already drops gc/stress), tier1_gc_epsilon, tier1_gc_shenandoah,
#                     tier1_runtime, tier1_serviceability. The GC stress tests measure collector
#                     throughput under load and say nothing a port changes, at the cost of an hour.
#            jdk      tier1's java/lang part, its jdk_lang group as TEST.groups defines it (java/lang
#                     without java/lang/management and java/lang/instrument, plus the small sun/invoke,
#                     sun/misc, sun/reflect, jdk/lambda, jdk/modules, jdk/internal/* and jni/nullCaller
#                     directories it names), then java/nio, java/net, java/util/concurrent and
#                     javax/net/ssl whole: the libc-facing code where a 10.9 port can break (files,
#                     selectors, sockets, DNS, threads, TLS). tier1 itself has only java/nio/Buffer of these.
#          Every run excludes keyword headful (the guest has no window server), and also native
#          (tests whose JNI libraries come from a test image) unless JTREG_NATIVEPATH names the test
#          natives build/build-jdk.sh leaves in the build root's test-natives: then each root runs
#          them with -nativepath:<JTREG_NATIVEPATH>/<root>/jtreg/native. Every run passes the options make test
#          uses: -agentvm, -automatic, -ignore:quiet, -timeoutFactor:4, -retain:fail,error, and
#          MaxRAMPercentage 25/<conc> per test JVM.
#          JTREG_HOME defaults to build/toolchain.sh's jdk_jtreg built with <JDK_HOME>; JTREG_SRC to the
#          source build/fetch-jdk.sh fetches into the build root's jtreg-src (replaced each run);
#          JTREG_WORK, where each root's work/ and report/ go (replaced each run), to the build root's
#          jtreg; JTREG_CONC, jtreg's -conc, to half the CPUs; JTREG_ROOTS to both roots, and a
#          listed test of a root that was not run is not checked.
#          It refuses to run when components/jtreg/version is not the jtreg the source's own CI runs
#          (JTREG_VERSION in its make/conf/github-actions.conf): a newer jtreg changes what its tests see.
#          Exits 77 when given no arguments, or a JDK this host's CPU does not run natively
#          (tests/lib/host-cpu.sh's jdk_runs_natively), without running it; 2 on a usage error.
set -eu
fail() { echo "FAIL: $*"; exit 1; }
usage() { echo "usage: tests/jtreg.sh <JDK_HOME> <known-failures-file>..." >&2; exit 2; }
if [ $# -eq 0 ]; then
  echo "SKIP: usage: tests/jtreg.sh <JDK_HOME> <known-failures-file>..."; exit 77
fi
[ $# -ge 2 ] || usage
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
jdk="$(cd "$1" 2>/dev/null && pwd)" || fail "no directory $1"
shift
[ -x "$jdk/bin/java" ] || fail "$jdk/bin/java is not executable"
knowns=""; nl='
'
for k in "$@"; do
  case "$k" in /*) ;; *) k="$PWD/$k" ;; esac
  case "$k" in *"$nl"*) fail "a known-failures file name holds a newline" ;; esac
  [ -r "$k" ] || fail "cannot read $k"
  knowns="$knowns${knowns:+$nl}$k"
done
known="$(printf '%s\n' "$knowns" | sed 's|.*/||' | tr '\n' ' ' | sed 's/ $//; s/ / and /g')"
# spec: PORT.md ruling R18 -- decided by the host's CPU, never by trying: under Rosetta it would run
. "$here/lib/host-cpu.sh"
jdk_runs_natively "$jdk" || { echo "SKIP: this host's CPU does not run the JDK at $jdk natively (PORT.md ruling R18)"; exit 77; }

conc="${JTREG_CONC:-}"
if [ -z "$conc" ]; then
  conc="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)"; conc=$((conc / 2)); [ "$conc" -ge 1 ] || conc=1
fi
case "$conc" in *[!0-9]*|0*) echo "JTREG_CONC is $conc, not a positive number" >&2; exit 2 ;; esac
roots="${JTREG_ROOTS:-hotspot jdk}"
for r in $roots; do case "$r" in hotspot|jdk) ;; *) echo "JTREG_ROOTS names $r, not hotspot or jdk" >&2; exit 2 ;; esac; done
[ -n "$(printf '%s' "$roots" | tr -d ' ')" ] || { echo "JTREG_ROOTS is empty" >&2; exit 2; }
natives=""
if [ -n "${JTREG_NATIVEPATH:-}" ]; then
  natives="$(cd "$JTREG_NATIVEPATH" 2>/dev/null && pwd)" || { echo "JTREG_NATIVEPATH: no directory $JTREG_NATIVEPATH" >&2; exit 2; }
  for r in $roots; do
    [ -d "$natives/$r/jtreg/native" ] || { echo "JTREG_NATIVEPATH has no $r/jtreg/native" >&2; exit 2; }
  done
fi

t="$(mktemp -d "${TMPDIR:-/tmp}/jtreg.XXXXXX")"
trap 'rm -rf "$t"' EXIT
: > "$t/listed"
# spec: PORT.md ruling R54 -- each file is checked as one, and no test may be listed in two of them
: > "$t/all"
while IFS= read -r k; do
  awk -v roots=" $roots " -v d="$t" -v f="$k" '
    /^[ \t]*$/ || /^#/ { next }
    $0 !~ /^(hotspot|jdk):[^ \t]+[ \t]+#[ \t]*[^ \t]/ {
      printf "%s: line %d is not `<hotspot|jdk>:<test id>  # <reason>`: %s\n", f, FNR, $0; bad = 1; next }
    { id = $1 }
    seen[id]++ { printf "%s: line %d lists %s again\n", f, FNR, id; bad = 1; next }
    { print id "\t" f >> (d "/all") }
    index(roots, " " substr(id, 1, index(id, ":") - 1) " ") { print id >> (d "/listed") }
    END { exit bad }' "$k" > "$t/known-errors" || fail "$(cat "$t/known-errors")"
done <<KNOWNS
$knowns
KNOWNS
awk -F '\t' 'first[$1] != "" { printf "%s lists %s, which %s also lists\n", $2, $1, first[$1]; bad = 1; next } { first[$1] = $2 } END { exit bad }' \
  "$t/all" > "$t/known-errors" || fail "$(cat "$t/known-errors")"
LC_ALL=C sort -o "$t/listed" "$t/listed"

need_toolchain() { [ -n "${_tc:-}" ] || { . "$MAVERICKS_ROOT/build/toolchain.sh"; _tc=1; }; }
if [ -n "${JTREG_WORK:-}" ]; then work="$JTREG_WORK"; else need_toolchain; work="$(jdk_build_root)/jtreg"; fi
if [ -n "${JTREG_SRC:-}" ]; then src="$JTREG_SRC"
else
  need_toolchain; src="$(jdk_build_root)/jtreg-src"
  sh "$MAVERICKS_ROOT/build/fetch-jdk.sh" "$src" || fail "could not fetch the jdk source"
fi
[ -d "$src/test/hotspot/jtreg" ] && [ -d "$src/test/jdk" ] || fail "$src has no test/hotspot/jtreg and test/jdk"
want_jt="$(sed -n 's/^JTREG_VERSION=//p' "$src/make/conf/github-actions.conf" 2>/dev/null | tr -d '[:space:]')"
[ -n "$want_jt" ] || fail "$src/make/conf/github-actions.conf names no JTREG_VERSION"
pin_jt="$(sed -n 's/^TAG=jtreg-//p' "$MAVERICKS_ROOT/components/jtreg/version" | tr -d '[:space:]')"
[ "$pin_jt" = "$want_jt" ] || fail "components/jtreg/version pins jtreg $pin_jt, but the jdk source's own CI runs jtreg $want_jt; move the pin to jtreg-$want_jt"
if [ -n "${JTREG_HOME:-}" ]; then jtreg_home="$JTREG_HOME"
else need_toolchain; jtreg_home="$(jdk_jtreg "$jdk")" || fail "could not build jtreg"
fi
[ -x "$jtreg_home/bin/jtreg" ] || fail "$jtreg_home/bin/jtreg is not executable"
ram="$(awk -v c="$conc" 'BEGIN { print 25 / c }')"

: > "$t/ran"; : > "$t/failing"; : > "$t/passed"
for root in $roots; do
  case "$root" in
    hotspot)
      tr="$src/test/hotspot/jtreg"; set --
      for g in tier1_common tier1_compiler tier1_gc_1 tier1_gc_2 tier1_gc_epsilon tier1_gc_shenandoah tier1_runtime tier1_serviceability; do
        set -- "$@" "$tr:$g"
      done ;;
    jdk)
      tr="$src/test/jdk"
      set -- "$tr:jdk_lang" "$tr/java/nio" "$tr/java/net" "$tr/java/util/concurrent" "$tr/javax/net/ssl" ;;
  esac
  rm -rf "$work/$root"; mkdir -p "$work/$root"
  report="$work/$root/report"
  echo "==> jtreg $root: $# selections, -conc:$conc, report $report"
  if [ -n "$natives" ]; then set -- "-nativepath:$natives/$root/jtreg/native" "-k:!headful" "$@"
  else set -- "-k:!headful&!native" "$@"
  fi
  rm -f "$t/rc"
  { rc=0
    JT_JAVA="$jdk/bin/java" "$jtreg_home/bin/jtreg" "-jdk:$jdk" -agentvm -automatic -ignore:quiet -timeoutFactor:4 \
      -retain:fail,error -verbose:summary "-conc:$conc" "-vmoption:-XX:MaxRAMPercentage=$ram" \
      "-exclude:$tr/ProblemList.txt" "-w:$work/$root/work" "-r:$report" "$@" || rc=$?
    echo "$rc" > "$t/rc"; } 2>&1 | tee "$work/$root/jtreg.log"
  [ -s "$t/rc" ] || fail "$root: jtreg exited without reporting a status"
  rc="$(cat "$t/rc")"
  results="$(grep '^Test results:' "$work/$root/jtreg.log" | tail -1 || :)"
  [ -n "$results" ] || fail "$root: jtreg did not finish: its output has no Test results: line (exit status $rc)"
  [ -f "$report/text/summary.txt" ] || fail "$root: jtreg wrote no $report/text/summary.txt (exit status $rc)"
  awk -v root="$root" -v d="$t" '
    NF == 0 { next }
    $2 == "Passed." { print root ":" $1 >> (d "/passed"); p++ }
    $2 == "Failed." { print root ":" $1 >> (d "/failing"); f++ }
    $2 == "Error." { print root ":" $1 >> (d "/failing"); e++ }
    $2 != "Passed." && $2 != "Failed." && $2 != "Error." { printf "unknown status %s for %s\n", $2, $1; bad = 1 }
    { print root ":" $1 >> (d "/ran") }
    END { printf "%d %d %d\n", p, f, e; exit bad }' "$report/text/summary.txt" > "$t/counts" \
    || fail "$root: $(cat "$t/counts")"
  read -r p f e < "$t/counts"
  [ $((p + f + e)) -gt 0 ] || fail "$root: jtreg ran no tests ($results)"
  said() { printf '%s\n' "$results" | tr -d , | sed -n "s/.*[:;] $1: \([0-9][0-9]*\).*/\1/p"; }
  sp="$(said passed)"; sf="$(said failed)"; se="$(said error)"
  [ "${sp:-0}" -eq "$p" ] && [ "${sf:-0}" -eq "$f" ] && [ "${se:-0}" -eq "$e" ] || {
    es=errors; [ "$e" -ne 1 ] || es=error
    fail "$root: the summary has $p passed, $f failed, $e $es, but jtreg said ${results#Test results: }"; }
  want=0; if [ "$e" -gt 0 ]; then want=3; elif [ "$f" -gt 0 ]; then want=2; fi
  [ "$rc" -eq "$want" ] || fail "$root: jtreg exited $rc, but with $f failed and $e errors it exits $want (1 no tests, 4 bad arguments, 5 a fault, 6 an exception)"
done

for f in ran failing passed; do LC_ALL=C sort -u -o "$t/$f" "$t/$f"; done
LC_ALL=C comm -23 "$t/failing" "$t/listed" > "$t/unlisted"
LC_ALL=C comm -23 "$t/listed" "$t/ran" > "$t/missing"
LC_ALL=C comm -12 "$t/listed" "$t/passed" > "$t/stale"
while read -r id; do echo "stale: $id"; done < "$t/stale"
if [ -s "$t/unlisted" ] || [ -s "$t/missing" ]; then
  while read -r id; do echo "FAIL: failed, and $known does not list: $id"; done < "$t/unlisted"
  while read -r id; do echo "FAIL: listed in $known, but did not run: $id"; done < "$t/missing"
  exit 1
fi
n() { wc -l < "$1" | tr -d ' '; }
echo "PASS: jtreg: $(n "$t/ran") tests, $(n "$t/failing") failing, exactly the ones $known lists, $(n "$t/stale") stale"
