#!/bin/sh
# platform: macOS-only -- runs tests/smoke-usr-bin.sh against jdk_boot_jdk's JDK, which runs only on arm64 macOS 11+ or where jdk25 is installed
#   usage: sh tests/smoke-usr-bin-test.sh
#          Drives tests/smoke-usr-bin.sh off Mac OS X 10.9: a /usr/bin of symlinks into the boot JDK's
#          bin, a java_home script, a console file this user owns, an open that runs the jar as Jar
#          Launcher would, and a ps that lists canned paths. Each case breaks one thing the smoke must
#          catch. What only 10.9 proves (Apple's stubs, their installer's process name, Jar Launcher)
#          is not here. Exits 77 where the boot JDK cannot run.
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
v="$("$J/bin/java" -version 2>&1)" || fail "$J/bin/java -version failed: $v"
jver="$(printf '%s\n' "$v" | sed -n 's/.*version "\([^"]*\)".*/\1/p' | sed -n 1p)"
jrev="$(printf '%s\n' "$v" | sed -n 's/.*(build [^)]*-\([^)-]*\)).*/\1/p' | sed -n 1p)"
[ -n "$jver" ] && [ -n "$jrev" ] || fail "cannot read a version and a -REV) from: $v"

T="$(mktemp -d "${TMPDIR:-/tmp}/smoke-usr-bin-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir "$T/bin" "$T/ok" "$T/prompt" "$T/home" "$T/home/bin"
for t in java javac jar; do ln -s "$J/bin/$t" "$T/ok/$t"; ln -s "$J/bin/$t" "$T/prompt/$t"; done
rm "$T/prompt/java"
cat > "$T/prompt/java" <<EOF
#!/bin/sh
echo "No Java runtime present, requesting install." >&2
exec "$J/bin/java" "\$@"
EOF
for e in "$J"/*; do [ "$(basename "$e")" = bin ] || ln -s "$e" "$T/home/"; done
for e in "$J"/bin/*; do ln -s "$e" "$T/home/bin/"; done
rm "$T/home/bin/jshell"
printf '#!/bin/sh\necho 41\n' > "$T/home/bin/jshell"
cat > "$T/bin/java_home" <<'EOF'
#!/bin/sh
case "$1" in
  -V) printf 'Matching Java Virtual Machines (1):\n    25, x86_64:\t"%s"\t%s\n\n' "$FAKE_JH_NAME" "$FAKE_JH_HOME" >&2; echo "$FAKE_JH_HOME" ;;
  -v) echo "$FAKE_JH_HOME" ;;
  *) exit 2 ;;
esac
EOF
cat > "$T/bin/open" <<EOF
#!/bin/sh
[ "\$1" = -a ] || exit 2
[ -n "\${FAKE_OPEN_IGNORES:-}" ] && exit 0
(sleep 1; "$J/bin/java" -jar "\$3") > /dev/null 2>&1 &
EOF
cat > "$T/bin/ps" <<'EOF'
#!/bin/sh
n="$(cat "$FAKE_PS_N" 2> /dev/null || echo 0)"; echo $((n + 1)) > "$FAKE_PS_N"
echo /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow
[ "$n" -ge 1 ] || exit 0
echo /System/Library/PrivateFrameworks/PackageKit.framework/Resources/installd
[ -n "${FAKE_PS_LATER:-}" ] && echo "$FAKE_PS_LATER"
exit 0
EOF
chmod +x "$T/prompt/java" "$T/home/bin/jshell" "$T/bin/java_home" "$T/bin/open" "$T/bin/ps"
touch "$T/console"

n=0
run() {
  n=$((n + 1))
  rc=0
  env SMOKE_USR_BIN="${U:-$T/ok}" SMOKE_JAVA_HOME_TOOL="$T/bin/java_home" SMOKE_CONSOLE="${C:-$T/console}" \
    SMOKE_OPEN="$T/bin/open" SMOKE_PS="$T/bin/ps" SMOKE_JAR_LAUNCHER="Jar Launcher" SMOKE_JAR_WAIT=10 \
    FAKE_JH_NAME="${NAME:-Mavericks JDK 25}" FAKE_JH_HOME="${H:-$J}" FAKE_PS_N="$T/ps.$n" \
    FAKE_OPEN_IGNORES="${IGN:-}" FAKE_PS_LATER="${LATER:-}" \
    sh "$here/smoke-usr-bin.sh" "${H:-$J}" "${V:-$jver}" "$jrev" > "$T/out.$n" 2>&1 || rc=$?
  out="$(cat "$T/out.$n")"
}
expect() {
  [ "$rc" -eq "$2" ] || fail "$1: exit $rc, not $2: $out"
  printf '%s\n' "$out" | grep -F -- "$3" > /dev/null || fail "$1: no '$3' in: $out"
  echo "ok $1"
}

run; expect "everything works, installd appearing does not count" 0 'ok open -a "Jar Launcher" hello.jar ran it'
printf '%s\n' "$out" | grep -F 'PASS: smoke-usr-bin' > /dev/null || fail "no PASS line: $out"
C=/dev/null run; expect "no window server: Jar Launcher skipped, the rest passes" 0 "skipped: no window server"
printf '%s\n' "$out" | grep -F 'PASS: smoke-usr-bin' > /dev/null || fail "the skip failed the run: $out"; C=
LATER='/System/Library/CoreServices/Java Updater.app/Contents/MacOS/Java Updater' run
expect "a Java Updater appears" 1 "an installer appeared"; LATER=
LATER='/System/Library/CoreServices/Install Java.app/Contents/MacOS/Install Java' run
expect "an Install app appears" 1 "an installer appeared"; LATER=
NAME="Java SE 25" run; expect "java_home -V lacks Mavericks JDK 25" 1 'does not list "Mavericks JDK 25"'; NAME=
U="$T/prompt" run; expect "the stub asks to install Java" 1 "asked to install Java"; U=
V=25.0.4 run; expect "another version answers" 1 "does not report 25.0.4"; V=
H="$T/home" run; expect "jshell gets 6*7 wrong" 1 "printed '41' for 6*7"; H=
IGN=1 run; expect "Jar Launcher runs nothing" 1 "wrote no marker within 10 s"; IGN=
echo "PASS: smoke-usr-bin-test ($n cases)"
