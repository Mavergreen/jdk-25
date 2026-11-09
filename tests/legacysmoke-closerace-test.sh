#!/bin/sh
# platform: macOS-only -- runs LegacySmoke's closeRace step on jdk_boot_jdk's JDK, which runs only on arm64 macOS 11+ or where jdk25 is installed
#   usage: sh tests/legacysmoke-closerace-test.sh
#          LegacySmoke's close-race steps closeRace and udpCloseRace (PORT.md ruling R66) must pass on
#          a JDK whose socket close does not wait, and closeRace, which shares their loop with
#          acceptCloseRace, must fail in under 15 s, naming the iteration, when a close is stuck
#          (legacysmoke.closeRace.stallAt=N holds iteration N's close for 20 s) or a reader does not
#          finish after its close (legacysmoke.closeRace.blockerStallAt=N holds it 20 s): well before
#          the hold ends, so the step did not wait it out. acceptCloseRace is not run here: even current
#          XNU checks SS_DRAINING in accept only after sleeping, and stock JDK 25 on this arm64 Mac
#          stalled it past 3 s in 2 of 8 runs, so only a JDK linked with Recaulk's close-race fix, on
#          10.9, passes it. Only 10.9 shows the real stall (a JDK without that fix); this tests the
#          watchdogs anywhere.
#          Exits 77 where the boot JDK cannot run.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
fail() { echo "FAIL $*" >&2; exit 1; }
if [ ! -x /usr/local/mavergreen/jdk25/bin/java ]; then
  if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ] || [ "$(uname -r | cut -d. -f1)" -lt 20 ]; then
    echo "SKIP: the pinned boot JDK runs only on arm64 macOS 11+ (or with /usr/local/mavergreen/jdk25 installed)"; exit 77
  fi
fi
. "$MAVERICKS_ROOT/build/toolchain.sh"
J="$(jdk_boot_jdk)" || fail "jdk_boot_jdk failed"
# spec: PORT.md ruling R18 -- the boot JDK runs only where this CPU runs it untranslated
. "$here/lib/host-cpu.sh"
jdk_runs_natively "$J" || { echo "SKIP: this host's CPU does not run the JDK at $J natively (PORT.md ruling R18)"; exit 77; }

T="$(mktemp -d "${TMPDIR:-/tmp}/legacysmoke-closerace-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir "$T/src" "$T/classes"
cp "$here/java/LegacySmoke.java" "$T/src/"
cat > "$T/src/CloseRaceOnly.java" <<'EOF'
public class CloseRaceOnly {
    public static void main(String[] a) {
        LegacySmoke.run("closeRace", LegacySmoke::closeRace);
        if (a.length > 0) {
            LegacySmoke.run("udpCloseRace", LegacySmoke::udpCloseRace);
        }
        System.exit(LegacySmoke.failures == 0 ? 0 : 1);
    }
}
EOF
"$J/bin/javac" -d "$T/classes" "$T/src/LegacySmoke.java" "$T/src/CloseRaceOnly.java" > "$T/javac.out" 2>&1 \
  || { cat "$T/javac.out" >&2; fail "javac could not compile LegacySmoke.java"; }

rc=0
"$J/bin/java" -Djava.awt.headless=true -cp "$T/classes" CloseRaceOnly all > "$T/ok.out" 2>&1 || rc=$?
for s in closeRace udpCloseRace; do
  [ "$rc" -eq 0 ] && grep -qx "ok $s" "$T/ok.out" || fail "$s did not pass on $J: exit $rc: $(cat "$T/ok.out")"
done
echo "ok closeRace and udpCloseRace pass where a close does not wait"

stalls() {
  rc=0
  start="$(date +%s)"
  "$J/bin/java" -Djava.awt.headless=true "-D$2" -cp "$T/classes" CloseRaceOnly > "$T/$1.out" 2>&1 || rc=$?
  took=$(( $(date +%s) - start ))
  [ "$rc" -eq 1 ] || fail "$1: exit $rc, not 1: $(cat "$T/$1.out")"
  grep -qF "$3" "$T/$1.out" || fail "$1: no '$3' line: $(cat "$T/$1.out")"
  [ "$took" -lt 15 ] || fail "$1: the step took ${took} s to fail, not under 15 s of a 20 s hold, so it waited for the hold"
  echo "ok $1 fails the step, naming its iteration (${took} s)"
}
stalls "a close stuck at iteration 1130" legacysmoke.closeRace.stallAt=1130 \
  "FAIL closeRace: java.lang.AssertionError: close() blocked >3000 ms at iteration 1130 of "
stalls "a reader not finishing at iteration 700" legacysmoke.closeRace.blockerStallAt=700 \
  "FAIL closeRace: java.lang.AssertionError: the thread in read() had not finished 3000 ms after close() returned, at iteration 700 of "
echo "PASS legacysmoke-closerace-test"
