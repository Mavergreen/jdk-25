#!/bin/sh
# platform: host-agnostic
#   Drives tests/smoke-runtime.sh with a fake JDK_HOME whose bin/ tools are stub shell scripts printing
#   canned output, so the wrapper's own logic is tested without a JDK 25. LegacySmoke.java itself is
#   validated against a real JDK 25, not here.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/smoke-runtime.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/smoke-runtime-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL $*" >&2; exit 1; }

ALL_OK='ok clocks
ok fileCopy
ok zip
ok udp
ok tcp
ok urgentData
ok tls
ok process
ok headless
ok fonts
ok closeRace
ok acceptCloseRace
ok udpCloseRace'

mkjdk() {  # mkjdk DIR
  rm -rf "$1"; mkdir -p "$1/bin"
  cat > "$1/bin/java" <<'S'
#!/bin/sh
echo "$*" >> "$FAKE_LOG"
case "$*" in
  *LegacySmoke*) cat "$FAKE_SMOKE_OUT"; exit "${FAKE_SMOKE_RC:-0}" ;;
  *--list-modules*) echo java.base ;;
  *) echo "openjdk 25 fake" ;;
esac
S
  cat > "$1/bin/javac" <<'S'
#!/bin/sh
[ "$1" = --version ] && { echo "javac 25"; exit 0; }
[ "$1" = -d ] && mkdir -p "$2"
exit 0
S
  cat > "$1/bin/jshell" <<'S'
#!/bin/sh
[ "$1" = --version ] && { echo "jshell 25"; exit 0; }
if [ "$1" = -s ] && [ -f "${2:-}" ]; then echo "${FAKE_JSHELL_OUT:-42}"; exit 0; fi
cat > /dev/null
echo "-> ${FAKE_JSHELL_OUT:-42}"
S
  cat > "$1/bin/jlink" <<'S'
#!/bin/sh
[ "$1" = --version ] && { echo "25"; exit 0; }
out=
while [ $# -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done
mkdir -p "$out/bin"
cat > "$out/bin/java" <<'J'
#!/bin/sh
case "$*" in *--list-modules*) echo java.base ;; *) echo fake image ;; esac
J
chmod +x "$out/bin/java"
S
  for t in javadoc jar javap jdeps jmod; do
    printf '#!/bin/sh\necho "%s 25"\n' "$t" > "$1/bin/$t"
  done
  printf '#!/bin/sh\nexit 2\n' > "$1/bin/jfoo"
  chmod +x "$1"/bin/*
}

run() {  # run JDKDIR [wrapper args]; sets rc, out, err
  d="$1"; shift
  rc=0
  JDK_HOME="$d" FAKE_LOG="$T/log" FAKE_SMOKE_OUT="$T/smoke.out" SMOKE_TOOL_SECONDS=2 \
    sh "$script" "$@" > "$T/stdout" 2> "$T/stderr" || rc=$?
}
has() { grep -q -- "$2" "$1" || fail "$3: expected '$2' in $1: $(cat "$1")"; }
hasnt() { ! grep -q -- "$2" "$1" || fail "$3: unexpected '$2' in $1: $(cat "$1")"; }

J="$T/jdk"
mkjdk "$J"
: > "$T/log"

echo "$ALL_OK" > "$T/smoke.out"
run "$J"
[ "$rc" = 0 ] || fail "all ok: exit $rc: $(cat "$T/stderr")"
has "$T/stdout" '^ok clocks' "all ok"
has "$T/stdout" '^ok jshell' "all ok"
has "$T/stdout" '^ok jlink' "all ok"
has "$T/stdout" '^ok version-javac' "all ok"
hasnt "$T/stdout" '^ok version-jfoo' "all ok"
has "$T/stdout" 'skip version-jfoo' "all ok"
has "$T/log" '-Djava.awt.headless=true' "every run asks for headless"
hasnt "$T/log" '--network' "default run"

: > "$T/log"
SMOKE_STOCK_JDK=1 run "$J"
[ "$rc" = 0 ] || fail "stock jdk: exit $rc"
has "$T/log" '-Djava.awt.headless=true' "SMOKE_STOCK_JDK=1"

: > "$T/log"
run "$J" --network
[ "$rc" = 1 ] || fail "--network without 'ok https': expected exit 1, got $rc"
has "$T/stderr" 'https' "--network without 'ok https'"
has "$T/log" '--network' "--network passed to LegacySmoke"
echo 'ok https' >> "$T/smoke.out"
run "$J" --network
[ "$rc" = 0 ] || fail "--network with 'ok https': exit $rc: $(cat "$T/stderr")"

echo "$ALL_OK" | sed 's/^ok tls$/FAIL tls: handshake timed out/' > "$T/smoke.out"
FAKE_SMOKE_RC=1 run "$J"
[ "$rc" = 1 ] || fail "one FAIL: expected exit 1, got $rc"
has "$T/stderr" 'tls' "one FAIL names the check"
has "$T/stderr" 'handshake timed out' "one FAIL carries the reason"

echo "$ALL_OK" > "$T/smoke.out"
FAKE_SMOKE_RC=3 run "$J"
[ "$rc" = 1 ] || fail "nonzero program exit without FAIL line: expected 1, got $rc"

echo "$ALL_OK" | grep -v '^ok udp$' > "$T/smoke.out"
run "$J"
[ "$rc" = 1 ] || fail "missing ok line: expected 1, got $rc"
has "$T/stderr" 'udp' "missing ok line names the check"

echo "$ALL_OK" > "$T/smoke.out"
FAKE_JSHELL_OUT=41 run "$J"
[ "$rc" = 1 ] || fail "jshell wrong answer: expected 1, got $rc"
has "$T/stderr" 'jshell' "jshell wrong answer"

rm "$J/bin/javap"
run "$J"
[ "$rc" = 1 ] || fail "listed tool absent: expected 1, got $rc"
has "$T/stderr" 'version-javap' "listed tool absent"

unset FAKE_SMOKE_RC FAKE_JSHELL_OUT
echo "$ALL_OK" > "$T/smoke.out"
mkjdk "$J"
printf '#!/bin/sh\nexec sleep 600\n' > "$J/bin/jhang"; chmod +x "$J/bin/jhang"
run "$J"
[ "$rc" = 0 ] || fail "unlisted tool hangs on --version: expected 0, got $rc: $(cat "$T/stderr")"
has "$T/stdout" 'skip version-jhang (did not exit within 2s' "unlisted tool hangs on --version"

mkjdk "$J"
printf '#!/bin/sh\nexec sleep 600\n' > "$J/bin/javap"; chmod +x "$J/bin/javap"
run "$J"
[ "$rc" = 1 ] || fail "listed tool hangs on --version: expected 1, got $rc"
has "$T/stderr" 'FAIL version-javap: did not exit within 2s' "listed tool hangs on --version"

mkjdk "$J"
chmod -x "$J/bin/java"
run "$J"
[ "$rc" = 77 ] || fail "non-executable java: expected 77, got $rc"

mkjdk "$J"
printf '#!/bin/sh\nexit 126\n' > "$J/bin/java"; chmod +x "$J/bin/java"
run "$J"
[ "$rc" = 1 ] || fail "a script java that exits 126 (a broken java, not a foreign CPU): expected 1, got $rc"

# spec: PORT.md ruling R18 -- a java of the architecture this host does not run natively (x86_64 on an
#       arm64 Mac, Rosetta or not) is never executed: 77, with nothing of the JDK run
mkjdk "$J"
. "$here/lib/host-cpu.sh"
if host_runs_x86_64; then
  printf '\317\372\355\376\014\000\000\001\000\000\000\000\002\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' > "$J/bin/java"
else
  printf '\317\372\355\376\007\000\000\001\003\000\000\000\002\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' > "$J/bin/java"
fi
chmod +x "$J/bin/java"
printf '#!/bin/sh\necho ran >> "%s/foreign-ran"\nexit 0\n' "$T" > "$J/bin/javac"; chmod +x "$J/bin/javac"
run "$J"
[ "$rc" = 77 ] || fail "a java of a CPU this host does not run natively: expected 77, got $rc"
[ ! -e "$T/foreign-ran" ] || fail "a java of a CPU this host does not run natively: the JDK's tools ran"
mv "$J/bin/java" "$T/foreign-java"; ln -s "$T/foreign-java" "$J/bin/java"
run "$J"
[ "$rc" = 77 ] || fail "a symlink to a java of a CPU this host does not run natively: expected 77, got $rc"
[ ! -e "$T/foreign-ran" ] || fail "a symlink to a java of a CPU this host does not run natively: the JDK's tools ran"
mkjdk "$J"
if host_runs_x86_64; then foreign=aarch64; else foreign=x86_64; fi
printf 'JAVA_VERSION="25"\nOS_ARCH="%s"\n' "$foreign" > "$J/release"
printf '#!/bin/sh\necho ran >> "%s/foreign-ran"\nexit 0\n' "$T" > "$J/bin/javac"; chmod +x "$J/bin/javac"
: > "$T/log"
run "$J"
[ "$rc" = 77 ] || fail "a script launcher in a JDK whose release says OS_ARCH=$foreign: expected 77, got $rc"
[ ! -e "$T/foreign-ran" ] && [ ! -s "$T/log" ] || fail "a script launcher in an $foreign JDK: the JDK ran ($(cat "$T/log" 2>/dev/null))"

mkjdk "$J"
printf '#!/bin/sh\nexit 1\n' > "$J/bin/java"; chmod +x "$J/bin/java"
run "$J"
[ "$rc" = 1 ] || fail "java that runs but fails -version: expected 1, got $rc"

rc=0; env -u JDK_HOME sh "$script" > /dev/null 2>&1 || rc=$?
[ "$rc" = 77 ] || fail "JDK_HOME unset: expected 77 (nothing to smoke), got $rc"

echo "PASS smoke-runtime-test"
