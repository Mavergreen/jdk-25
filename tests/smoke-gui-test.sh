#!/bin/sh
# platform: macOS-only -- tests/smoke-gui.sh reads the console's owner with BSD stat -f
#   usage: sh tests/smoke-gui-test.sh
#          Drives tests/smoke-gui.sh with a fake JDK_HOME whose bin/javac and bin/java are shell
#          scripts printing canned GuiSmoke output, and SMOKE_CONSOLE pointing at a file this user owns
#          (or one root owns), so the wrapper's own logic is tested without a window. GuiSmoke.java
#          itself runs only on the 10.9 box under a console login.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/smoke-gui.sh"
[ "$(uname -s)" = Darwin ] || { echo "SKIP: smoke-gui reads the console's owner with BSD stat -f"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/smoke-gui-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL $*" >&2; exit 1; }

ALL_OK='ok headful
ok frame
ok screenmenubar
ok paint
ok pixel
ok resize
ok fullscreen
ok type
ok fonts
ok clipboard
ok dnd
ok badge
ok desktop
ok print
ok close
PASS GuiSmoke'
mkdir -p "$T/jdk/bin"
cat > "$T/jdk/bin/javac" <<'S'
#!/bin/sh
[ -n "${FAKE_JAVAC_FAILS:-}" ] && { echo "GuiSmoke.java:1: error: fake"; exit 1; }
[ "$1" = -d ] && mkdir -p "$2"
exit 0
S
cat > "$T/ioreg" <<'S'
#!/bin/sh
case "$*" in
  *IODisplayWrangler*) [ -n "${FAKE_DPS:-}" ] && printf '  | "IOPowerManagement" = {"DevicePowerState"=%s,"CurrentPowerState"=%s}\n' "$FAKE_DPS" "$FAKE_DPS" ;;
  *Root*) printf '  | "IOConsoleUsers" = ({"kCGSSessionOnConsoleKey"=No,"kCGSSessionUserNameKey"="root","CGSSessionScreenIsLocked"=Yes},{"kCGSSessionOnConsoleKey"=Yes,"kCGSSessionUserNameKey"="%s"%s,"kCGSSessionUserIDKey"=502})\n' "$(id -un)" "${FAKE_LOCKED:+,\"CGSSessionScreenIsLocked\"=Yes}" ;;
esac
exit 0
S
cat > "$T/jdk/bin/java" <<'S'
#!/bin/sh
echo "$*" >> "$FAKE_LOG"
[ -n "${FAKE_HANG:-}" ] && exec sleep 30
cat "$FAKE_OUT"
exit "${FAKE_RC:-0}"
S
chmod +x "$T/jdk/bin/javac" "$T/jdk/bin/java" "$T/ioreg"
touch "$T/console"

run() {
  rc=0
  env FAKE_LOG="$T/log" FAKE_OUT="$T/out" SMOKE_CONSOLE="$T/console" SMOKE_IOREG="$T/ioreg" JDK_HOME="$T/jdk" "$@" \
    sh "$script" > "$T/stdout" 2> "$T/stderr" || rc=$?
}
expect() {
  [ "$rc" -eq "$2" ] || fail "$1: exit $rc, not $2: $(cat "$T/stdout" "$T/stderr")"
  grep -F -- "$3" "$T/stdout" "$T/stderr" > /dev/null || fail "$1: no '$3' in: $(cat "$T/stdout" "$T/stderr")"
  echo "ok $1"
}

echo "$ALL_OK" > "$T/out"
run JDK_HOME=; expect "no JDK_HOME" 77 "SKIP smoke-gui: JDK_HOME is unset"
run SMOKE_CONSOLE=/dev/null; expect "no window server" 77 "SKIP smoke-gui: no window server: the console belongs to root"
grep -F 'no window server' "$T/stderr" > /dev/null || fail "no window server: the skip is not on stderr too"
: > "$T/log"; run; expect "every step ok" 0 "PASS: smoke-gui"
grep -F 'java.awt.headless' "$T/log" > /dev/null && fail "every step ok: the run passed -Djava.awt.headless"
grep -F -- '-cp' "$T/log" | grep -F 'GuiSmoke' > /dev/null || fail "every step ok: java did not run GuiSmoke: $(cat "$T/log")"
printf 'ok headful\nok frame\nok screenmenubar\nok paint\nFAIL pixel: Robot.getPixelColor is black\n' > "$T/out"
run FAKE_RC=1; expect "a step fails" 1 "FAIL pixel: reported by GuiSmoke: FAIL pixel: Robot.getPixelColor is black"
echo "$ALL_OK" | sed 's/^ok clipboard$/skip clipboard: the clipboard holds «class RTF », which this step could not put back exactly/' > "$T/out"
run; expect "a step skips" 0 "PASS: smoke-gui (skipped, as their skip lines say: clipboard)"
echo "$ALL_OK" | grep -v '^ok type$' > "$T/out"
run; expect "a step is missing" 1 "FAIL type: no ok line from GuiSmoke"
echo "$ALL_OK" > "$T/out"
run FAKE_RC=3; expect "GuiSmoke exits non-zero with every step ok" 1 "FAIL exit: GuiSmoke exited 3"
run FAKE_JAVAC_FAILS=1; expect "javac fails" 1 "FAIL compile: javac could not compile tests/java/GuiSmoke.java"
run FAKE_LOCKED=1; expect "the screen is locked" 77 "SKIP smoke-gui: the screen is locked (IOConsoleUsers: CGSSessionScreenIsLocked=Yes for"
grep -F 'the screen is locked' "$T/stderr" > /dev/null || fail "the screen is locked: the skip is not on stderr too"
run FAKE_DPS=1; expect "the display is asleep" 77 "SKIP smoke-gui: the display is asleep (IODisplayWrangler CurrentPowerState=1, not 4)"
: > "$T/log"; run FAKE_DPS=4; expect "the display is awake" 0 "PASS: smoke-gui"
: > "$T/log"; run SMOKE_GUI_SHOTS=/some/dir; expect "screenshots kept" 0 "PASS: smoke-gui"
grep -F -- '-Dguismoke.shots=/some/dir' "$T/log" > /dev/null || fail "screenshots kept: java got no -Dguismoke.shots: $(cat "$T/log")"
: > "$T/log"; run SMOKE_GUI_TRACE=1; expect "trace asked for" 0 "PASS: smoke-gui"
grep -F -- '-Dguismoke.trace=true' "$T/log" > /dev/null || fail "trace asked for: java got no -Dguismoke.trace=true: $(cat "$T/log")"
: > "$T/log"; run; grep -F 'guismoke.trace' "$T/log" > /dev/null && fail "no trace asked for: java got -Dguismoke.trace"
echo "ok no trace asked for"
grep -F 'guismoke.browse' "$T/log" > /dev/null && fail "no browse asked for: java got -Dguismoke.browse"
echo "ok no browse asked for"
: > "$T/log"; run SMOKE_GUI_BROWSE=1; expect "browse asked for" 0 "PASS: smoke-gui"
grep -F -- '-Dguismoke.browse=true' "$T/log" > /dev/null || fail "browse asked for: java got no -Dguismoke.browse=true: $(cat "$T/log")"
run FAKE_HANG=1 SMOKE_GUI_SECONDS=2; expect "GuiSmoke hangs" 1 "FAIL headful: no ok line from GuiSmoke"
echo "PASS smoke-gui-test"
