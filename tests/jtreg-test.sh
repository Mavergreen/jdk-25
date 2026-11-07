#!/bin/sh
# platform: host-agnostic
# usage: sh tests/jtreg-test.sh
#   Drives tests/jtreg.sh with a fake jtreg that writes canned report summaries and prints canned
#   "Test results:" lines, so the wrapper's verdict is tested without a JDK or jtreg. The subset itself
#   is run against a real image on Mac OS X 10.9, not here.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/jtreg.sh"
_tmp="${TMPDIR:-/tmp}"; t="$(cd -P "$(mktemp -d "${_tmp%/}/jtreg-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$t"' EXIT

mkdir -p "$t/jdk/bin" "$t/jtreg/bin" "$t/src/test/hotspot/jtreg" "$t/fx" "$t/src/make/conf"
pin="$(sed -n 's/^TAG=jtreg-//p' "$here/../components/jtreg/version")"
echo "JTREG_VERSION=$pin" > "$t/src/make/conf/github-actions.conf"
printf '#!/bin/sh\nexit 0\n' > "$t/jdk/bin/java"; chmod +x "$t/jdk/bin/java"
for d in java/nio java/net java/util/concurrent javax/net/ssl; do
  mkdir -p "$t/src/test/jdk/$d"
done
: > "$t/src/test/jdk/ProblemList.txt"; : > "$t/src/test/hotspot/jtreg/ProblemList.txt"

cat > "$t/jtreg/bin/jtreg" <<'EOF'
#!/bin/sh
r=""; root=""
for a; do
  case "$a" in
    -r:*) r="${a#-r:}" ;;
    */test/hotspot/jtreg:*) root=hotspot ;;
    */test/jdk/* | */test/jdk:*) root=jdk ;;
  esac
done
printf '%s\n' "$*" > "$FAKE_DIR/args.$root"
printf '%s\n' "$JT_JAVA" > "$FAKE_DIR/jt_java.$root"
s="$FAKE_DIR/$root.summary"
if [ -f "$s" ]; then mkdir -p "$r/text"; cp "$s" "$r/text/summary.txt"; fi
p=0; f=0; e=0
if [ -f "$s" ]; then
  p="$(grep -c ' Passed\. ' "$s" || :)"; f="$(grep -c ' Failed\. ' "$s" || :)"; e="$(grep -c ' Error\. ' "$s" || :)"
fi
if [ -f "$FAKE_DIR/$root.results" ]; then cat "$FAKE_DIR/$root.results"
else
  line="Test results:"; sep=" "
  [ "$p" -eq 0 ] || { line="$line${sep}passed: $(awk -v n="$p" 'BEGIN { if (n >= 1000) printf "%d,%03d", n / 1000, n % 1000; else print n }')"; sep="; "; }
  [ "$f" -eq 0 ] || { line="$line${sep}failed: $f"; sep="; "; }
  [ "$e" -eq 0 ] || { line="$line${sep}error: $e"; sep="; "; }
  echo "$line; did not match keywords: 3"
fi
if [ -f "$FAKE_DIR/$root.rc" ]; then exit "$(cat "$FAKE_DIR/$root.rc")"; fi
if [ "$e" -gt 0 ]; then exit 3; elif [ "$f" -gt 0 ]; then exit 2; elif [ "$p" -eq 0 ]; then exit 1; fi
exit 0
EOF
chmod +x "$t/jtreg/bin/jtreg"

cat > "$t/fx/hotspot.summary" <<'EOF'
runtime/Thread/Fibonacci.java                        Passed. Execution successful
runtime/Thread/ThreadCountLimit.java#id0             Failed. Execution failed: `main' threw exception: java.lang.OutOfMemoryError
gc/TestSmallHeap.java                                Passed. Execution successful
EOF
cat > "$t/fx/jdk.summary" <<'EOF'
java/lang/String/Basic.java                          Passed. Execution successful
java/net/Inet6Address/B6206527.java                  Failed. Execution failed: `main' threw exception: java.net.SocketException
java/nio/channels/Selector/Wakeup.java               Error. Program `java' timed out (timeout set to 480000ms, elapsed time including timeout handling was 480123ms).
javax/net/ssl/SSLEngine/Basics.java                  Passed. Execution successful
EOF
cat > "$t/fx/known.txt" <<'EOF'
hotspot:runtime/Thread/ThreadCountLimit.java#id0  # canned: thread limit
jdk:java/net/Inet6Address/B6206527.java  # canned: no IPv6

jdk:java/nio/channels/Selector/Wakeup.java  # canned: slow
EOF

conc=""; roots=""; natives=""
fixture() { rm -f "$t/fake/"*; mkdir -p "$t/fake"; cp "$t/fx/hotspot.summary" "$t/fx/jdk.summary" "$t/fake/"; }
extra=""
run() {  # run: jtreg.sh on $t/known, then each file $extra names
  # shellcheck disable=SC2086  # extra is a list of space-free paths
  JTREG_HOME="$t/jtreg" JTREG_SRC="$t/src" JTREG_WORK="$t/work" JTREG_CONC="$conc" JTREG_ROOTS="$roots" JTREG_NATIVEPATH="$natives" \
    FAKE_DIR="$t/fake" sh "$script" "$t/jdk" "$t/known" $extra > "$t/out" 2>&1
}
says() { grep -q -e "$1" "$t/out" || { echo "FAIL $2: wanted \"$1\" in: $(cat "$t/out")"; exit 1; }; }
passes() { run || { echo "FAIL $1: $(cat "$t/out")"; exit 1; }; }
fails() { if run; then echo "FAIL $1 passed: $(cat "$t/out")"; exit 1; fi; }

fixture; cp "$t/fx/known.txt" "$t/known"
passes "exact match"
says '^PASS: jtreg: 7 tests, 3 failing, exactly the ones' "exact match"
if grep -q '^stale:' "$t/out"; then echo "FAIL exact match reported a stale listing: $(cat "$t/out")"; exit 1; fi
h="$(cat "$t/fake/args.hotspot")"; j="$(cat "$t/fake/args.jdk")"
for w in "-jdk:$t/jdk" -agentvm -automatic -ignore:quiet -timeoutFactor:4 -retain:fail,error \
  "-k:!headful&!native" "-exclude:$t/src/test/hotspot/jtreg/ProblemList.txt" "-w:$t/work/hotspot/work" "-r:$t/work/hotspot/report" \
  "$t/src/test/hotspot/jtreg:tier1_common" "$t/src/test/hotspot/jtreg:tier1_compiler" "$t/src/test/hotspot/jtreg:tier1_gc_1" \
  "$t/src/test/hotspot/jtreg:tier1_gc_2" "$t/src/test/hotspot/jtreg:tier1_gc_epsilon" "$t/src/test/hotspot/jtreg:tier1_gc_shenandoah" \
  "$t/src/test/hotspot/jtreg:tier1_runtime" "$t/src/test/hotspot/jtreg:tier1_serviceability"; do
  case " $h " in *" $w "*) ;; *) echo "FAIL hotspot ran without $w: $h"; exit 1 ;; esac
done
case "$h" in *gcbasher*|*:tier1\ *|*:tier1_gc\ *) echo "FAIL hotspot ran the GC stress tests: $h"; exit 1 ;; esac
for w in "-exclude:$t/src/test/jdk/ProblemList.txt" "$t/src/test/jdk:jdk_lang" \
  "$t/src/test/jdk/java/nio" "$t/src/test/jdk/java/net" "$t/src/test/jdk/java/util/concurrent" "$t/src/test/jdk/javax/net/ssl"; do
  case " $j " in *" $w "*) ;; *) echo "FAIL jdk ran without $w: $j"; exit 1 ;; esac
done
case "$j" in *java/lang*|*hotspot*) echo "FAIL jdk ran outside the subset: $j"; exit 1 ;; esac
[ "$(cat "$t/fake/jt_java.jdk")" = "$t/jdk/bin/java" ] || { echo "FAIL jtreg itself did not run on the JDK under test"; exit 1; }
n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)"; n=$((n / 2)); [ "$n" -ge 1 ] || n=1
case " $h " in *" -conc:$n "*) ;; *) echo "FAIL default -conc is not half the CPUs ($n): $h"; exit 1 ;; esac

conc=3; passes "JTREG_CONC=3"
case " $(cat "$t/fake/args.jdk") " in *" -conc:3 -vmoption:-XX:MaxRAMPercentage=8.33333 "*) ;; *)
  echo "FAIL JTREG_CONC=3 ran as: $(cat "$t/fake/args.jdk")"; exit 1 ;; esac
conc=lots; rc=0; run || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL JTREG_CONC=lots exited $rc, not 2"; exit 1; }
conc=0; rc=0; run || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL JTREG_CONC=0 exited $rc, not 2"; exit 1; }
conc=""

mkdir -p "$t/natives/hotspot/jtreg/native" "$t/natives/jdk/jtreg/native"
natives="$t/natives"; passes "JTREG_NATIVEPATH"
for root in hotspot jdk; do
  a=" $(cat "$t/fake/args.$root") "
  case "$a" in *" -nativepath:$t/natives/$root/jtreg/native "*) ;; *) echo "FAIL $root ran without its -nativepath: $a"; exit 1 ;; esac
  case "$a" in *" -k:!headful "*) ;; *) echo "FAIL $root ran with natives but not -k:!headful: $a"; exit 1 ;; esac
  case "$a" in *"&!native"*) echo "FAIL $root still excluded native tests: $a"; exit 1 ;; esac
done
rm -r "$t/natives/jdk"; rc=0; run || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL JTREG_NATIVEPATH without jdk/jtreg/native exited $rc, not 2"; exit 1; }
says "JTREG_NATIVEPATH has no jdk/jtreg/native" "natives missing a root"
roots=hotspot; passes "JTREG_NATIVEPATH with only the root it runs"
roots=""; natives="$t/nowhere"; rc=0; run || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL JTREG_NATIVEPATH=nowhere exited $rc, not 2"; exit 1; }
natives=""

grep -v B6206527 "$t/fx/known.txt" > "$t/known"
fails "an unlisted failure"; says 'does not list: jdk:java/net/Inet6Address/B6206527.java$' "unlisted failure"
grep -v Wakeup "$t/fx/known.txt" > "$t/known"
fails "an unlisted error"; says 'does not list: jdk:java/nio/channels/Selector/Wakeup.java$' "unlisted error"
sed 's/^hotspot:runtime/jdk:runtime/' "$t/fx/known.txt" > "$t/known"
fails "a failure listed under the other root"; says 'does not list: hotspot:runtime/Thread/ThreadCountLimit.java#id0$' "other root"

{ cat "$t/fx/known.txt"; echo 'jdk:javax/net/ssl/SSLEngine/Basics.java  # canned: used to fail'; } > "$t/known"
passes "a listed test that now passes"
says '^stale: jdk:javax/net/ssl/SSLEngine/Basics.java$' "stale"
says ', 1 stale' "stale count"

{ cat "$t/fx/known.txt"; echo 'jdk:java/net/Gone.java  # canned: deleted upstream'; } > "$t/known"
fails "a listed test that did not run"; says 'did not run: jdk:java/net/Gone.java$' "listed, not run"

# spec: PORT.md ruling R54 -- the release gate's list and a host's overlay are read together
fixture; sed -n 1p "$t/fx/known.txt" > "$t/known"; sed -n '2,$p' "$t/fx/known.txt" > "$t/overlay"; extra="$t/overlay"
passes "the list split across two files"; says '^PASS: jtreg: 7 tests, 3 failing, exactly the ones' "two files"
{ echo 'jdk:java/net/Gone.java  # canned: deleted upstream'; } >> "$t/overlay"
fails "a listed test in the second file that did not run"; says "did not run: jdk:java/net/Gone.java$" "two files, not run"
sed -n '2,$p' "$t/fx/known.txt" > "$t/overlay"; echo 'jdk:javax/net/ssl/SSLEngine/Basics.java  # canned: used to fail here' >> "$t/overlay"
passes "a test the second file lists that now passes"; says '^stale: jdk:javax/net/ssl/SSLEngine/Basics.java$' "two files, stale"
sed -n '2,$p' "$t/fx/known.txt" > "$t/overlay"; sed -n 1p "$t/fx/known.txt" >> "$t/overlay"
fails "a test listed in both files"; says "lists hotspot:runtime/Thread/ThreadCountLimit.java#id0, which .*known also lists" "duplicate across files"
printf 'not a line\n' > "$t/overlay"
fails "a malformed second file"; says "overlay: line 1 is not" "malformed second file"
extra="$t/overlay $t/missing-file"; sed -n '2,$p' "$t/fx/known.txt" > "$t/overlay"
fails "a second file that cannot be read"; says "cannot read $t/missing-file" "unreadable second file"
extra=""

cp "$t/fx/known.txt" "$t/known"
rm -f "$t/fake/args."*; roots=jdk; passes "JTREG_ROOTS=jdk with a hotspot listing"
[ ! -e "$t/fake/args.hotspot" ] || { echo "FAIL JTREG_ROOTS=jdk ran hotspot"; exit 1; }
roots=bogus; rc=0; run || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL JTREG_ROOTS=bogus exited $rc, not 2"; exit 1; }
roots=""

fixture; echo 'Test results: passed: 1' > "$t/fake/jdk.results"
fails "counts that disagree with the summary"; says 'jdk: the summary has 2 passed, 1 failed, 1 error, but jtreg said passed: 1' "count mismatch"
fixture; : > "$t/fake/jdk.results"
fails "a run with no Test results: line"; says 'jdk: jtreg did not finish' "truncated"
fixture; rm "$t/fake/jdk.summary"
fails "a run with no summary"; says 'jdk: jtreg wrote no' "no summary"
fixture; : > "$t/fake/jdk.summary"; echo 'Test results: no tests selected' > "$t/fake/jdk.results"
fails "a run that selected nothing"; says 'jdk: jtreg ran no tests' "nothing selected"
fixture; echo 'java/net/Odd.java   Skipped. who knows' >> "$t/fake/jdk.summary"
fails "an unknown status"; says 'jdk: unknown status' "unknown status"
fixture; echo 0 > "$t/fake/jdk.rc"
fails "failures with exit status 0"; says 'jdk: jtreg exited 0' "status 0 with failures"
fixture; grep Passed "$t/fx/hotspot.summary" > "$t/fake/hotspot.summary"; echo 2 > "$t/fake/hotspot.rc"
grep -v ThreadCountLimit "$t/fx/known.txt" > "$t/known"
fails "no failures with exit status 2"; says 'hotspot: jtreg exited 2' "status 2 without failures"
fixture; echo 2 > "$t/fake/jdk.rc"; cp "$t/fx/known.txt" "$t/known"
fails "errors with exit status 2"; says 'jdk: jtreg exited 2' "status 2 with errors"
fixture; echo 5 > "$t/fake/jdk.rc"; cp "$t/fx/known.txt" "$t/known"
fails "jtreg exit status 5 (a fault)"; says 'jdk: jtreg exited 5' "status 5"
fixture

{ cat "$t/fx/known.txt"; echo 'jdk:java/net/Foo.java'; } > "$t/known"
fails "a listing with no reason"; says 'line 5 is not `<hotspot|jdk>:<test id>  # <reason>`' "no reason"
[ ! -e "$t/fake/args.jdk" ] || { echo "FAIL jtreg ran despite a malformed list"; exit 1; }
{ cat "$t/fx/known.txt"; echo 'langtools:tools/javac/Foo.java  # canned: wrong root'; } > "$t/known"
fails "an unknown root"; says 'line 5 is not' "unknown root"
{ cat "$t/fx/known.txt"; echo 'jdk:java/net/Inet6Address/B6206527.java  # again'; } > "$t/known"
fails "a duplicate listing"; says 'lists jdk:java/net/Inet6Address/B6206527.java again' "duplicate"

grep Passed "$t/fx/hotspot.summary" > "$t/fake/hotspot.summary"; grep Passed "$t/fx/jdk.summary" > "$t/fake/jdk.summary"; : > "$t/known"
passes "a clean run with an empty list"; says "^PASS: jtreg: 4 tests, 0 failing" "clean run"
fixture

fixture; cp "$t/fx/known.txt" "$t/known"
i=0; while [ $i -lt 1200 ]; do echo "gc/Many$i.java   Passed. Execution successful"; i=$((i + 1)); done >> "$t/fake/hotspot.summary"
passes "jtreg's thousands separators"; says "^PASS: jtreg: 1207 tests" "thousands"
grep -q "passed: 1,202" "$t/out" || { echo "FAIL the fake did not print 1,202: $(cat "$t/out")"; exit 1; }
fixture

echo "JTREG_VERSION=99+1" > "$t/src/make/conf/github-actions.conf"
fails "a jtreg pin that is not jdk25u's"; says "runs jtreg 99+1" "pin mismatch"
[ ! -e "$t/fake/args.hotspot" ] || { echo "FAIL jtreg ran with the wrong pin"; exit 1; }
rm "$t/src/make/conf/github-actions.conf"
fails "a source with no JTREG_VERSION"; says "names no JTREG_VERSION" "no conf"
echo "JTREG_VERSION=$pin" > "$t/src/make/conf/github-actions.conf"
fixture

cp "$t/fx/known.txt" "$t/known"; rm "$t/jdk/bin/java"
fails "a JDK with no bin/java"; says 'bin/java' "no java"
printf '#!/bin/sh\nexit 0\n' > "$t/jdk/bin/java"; chmod +x "$t/jdk/bin/java"

rc=0; sh "$script" > "$t/out" 2>&1 || rc=$?
[ "$rc" -eq 77 ] || { echo "FAIL no arguments exited $rc, not 77"; exit 1; }

echo "PASS: jtreg comparator (canned output)"
