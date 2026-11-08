#!/bin/sh
# platform: macOS-only -- needs this user's Aqua session (a console login) to open windows
#   usage: JDK_HOME=<dir> sh tests/smoke-gui.sh
#          Compiles tests/java/GuiSmoke.java with JDK_HOME's javac and runs it with JDK_HOME's java,
#          without -Djava.awt.headless, so the JDK's own default decides (gui: headful in an Aqua
#          session). It requires an "ok <step>" line for each of: headful frame screenmenubar paint
#          pixel resize fullscreen type fonts clipboard dnd badge desktop print close. The run sets the
#          clipboard and puts its text back, badges the Dock icon and clears it, opens an empty
#          temporary folder in Finder and closes its window (osascript), and prints one page to a
#          temporary PostScript file only. A step may print "skip <step>: <why>" instead of its ok line
#          (clipboard does, when the clipboard holds what it could not put back exactly); that passes
#          and is named in the PASS line. It opens nothing in the default browser unless
#          SMOKE_GUI_BROWSE=1, which browses a small temporary file: page there, for the eye. Exit 0 when all pass, 1 naming each failed step on
#          stderr, 77 when JDK_HOME is unset (run-repo-tests runs this bare), JDK_HOME/bin/java is not
#          executable, this host's CPU does not run the JDK natively, or nothing on screen can be seen:
#            no window server: /dev/console (SMOKE_CONSOLE) is not this user's, as smoke-usr-bin decides;
#            the screen is locked: this user's console session in ioreg's IOConsoleUsers says
#              CGSSessionScreenIsLocked=Yes;
#            the display is asleep: IODisplayWrangler's CurrentPowerState is below 4.
#          Either ioreg key may be absent; then that check decides nothing, and GuiSmoke's pixel FAIL
#          names a locked screen, an asleep display or ssh when it reads black. SMOKE_IOREG replaces
#          /usr/sbin/ioreg (the tests).
#          Run it from a process in the console's Aqua session, such as Terminal there, or from ssh with
#          open -a Terminal x.command. From an ssh session, even as the console's user, 10.9 gives
#          screen capture nothing (screencapture writes no file), so Robot reads black; this script does
#          not try to get round that.
#          SMOKE_GUI_SHOTS=DIR keeps GuiSmoke's screenshots there, each named with what to see:
#          screenmenubar.png (the screen's menu bar), hello.png (Lucida Grande), dock.png (the badge).
#          A failed dnd prints its trace (trace dnd: lines, what AWT, the drag source and the drop target
#          saw); SMOKE_GUI_TRACE=1 prints it on a pass too. GuiSmoke stops itself after 180 s; SMOKE_GUI_SECONDS (default 240)
#          bounds the whole run.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
steps="headful frame screenmenubar paint pixel resize fullscreen type fonts clipboard dnd badge desktop print close"
fail=0
bad() { echo "FAIL $1: $2" >&2; fail=1; }
skip() { echo "SKIP smoke-gui: $*; nothing headful was tested"; echo "SKIP smoke-gui: $*; nothing headful was tested" >&2; exit 77; }

if [ -z "${JDK_HOME:-}" ]; then
  echo "SKIP smoke-gui: JDK_HOME is unset (usage: JDK_HOME=<dir> sh $0)"; exit 77
fi
java="$JDK_HOME/bin/java"
[ -x "$java" ] || { echo "SKIP smoke-gui: $java is not executable"; exit 77; }
# spec: PORT.md ruling R18 -- decided by the host's CPU, never by trying: under Rosetta it would run
. "$here/lib/host-cpu.sh"
jdk_runs_natively "$JDK_HOME" || { echo "SKIP smoke-gui: this host's CPU does not run the JDK at $JDK_HOME natively (PORT.md ruling R18)"; exit 77; }
# spec: PORT.md ruling R60 -- a window needs this user's Aqua session, which the console's owner has
me="$(id -un)"
owner="$(stat -f %Su "${SMOKE_CONSOLE:-/dev/console}" 2> /dev/null || true)"
[ "$owner" = "$me" ] || skip "no window server: the console belongs to ${owner:-nobody}, not $me, so no window can open"
# platform: a locked screen or an asleep display still has this user on the console, but Robot reads
#           black there (the 10.9 box, 2026-11-07); ioreg is the shell's view of both
ioreg="${SMOKE_IOREG:-/usr/sbin/ioreg}"
if "$ioreg" -n Root -d1 2> /dev/null | tr '{}' '\n\n' | grep -F "\"kCGSSessionUserNameKey\"=\"$me\"" \
    | grep -F '"kCGSSessionOnConsoleKey"=Yes' | grep -qF '"CGSSessionScreenIsLocked"=Yes'; then
  skip "the screen is locked (IOConsoleUsers: CGSSessionScreenIsLocked=Yes for $me): unlock it"
fi
dps="$("$ioreg" -r -c IODisplayWrangler -d1 2> /dev/null | sed -n 's/.*"CurrentPowerState"=\([0-9]*\).*/\1/p' | sed -n 1p)"
if [ -n "$dps" ] && [ "$dps" -lt 4 ]; then
  skip "the display is asleep (IODisplayWrangler CurrentPowerState=$dps, not 4): wake it"
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/smoke-gui.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 1' HUP INT TERM
"$JDK_HOME/bin/javac" -d "$T/classes" "$here/java/GuiSmoke.java" > "$T/javac.out" 2>&1 \
  || { cat "$T/javac.out" >&2; echo "FAIL compile: javac could not compile tests/java/GuiSmoke.java" >&2; exit 1; }

prc=0
"$java" -cp "$T/classes" ${SMOKE_GUI_SHOTS:+"-Dguismoke.shots=$SMOKE_GUI_SHOTS"} ${SMOKE_GUI_TRACE:+-Dguismoke.trace=true} ${SMOKE_GUI_BROWSE:+-Dguismoke.browse=true} GuiSmoke > "$T/smoke.out" 2>&1 < /dev/null &
pid=$!
(sleep "${SMOKE_GUI_SECONDS:-240}"; kill -9 "$pid" 2> /dev/null) > /dev/null 2>&1 &
guard=$!
wait "$pid" || prc=$?
kill "$guard" 2> /dev/null || true
cat "$T/smoke.out"
for n in $(sed -n 's/^FAIL \([A-Za-z0-9_]*\):.*/\1/p' "$T/smoke.out"); do
  bad "$n" "reported by GuiSmoke: $(grep "^FAIL $n:" "$T/smoke.out" | head -1)"
done
skipped=""
for n in $steps; do
  if grep -q "^skip $n:" "$T/smoke.out"; then
    skipped="$skipped $n"
  else
    grep -q "^ok $n\$" "$T/smoke.out" || bad "$n" "no ok line from GuiSmoke"
  fi
done
[ "$prc" -eq 0 ] || bad exit "GuiSmoke exited $prc"
[ "$fail" -eq 0 ] || exit 1
if [ -n "$skipped" ]; then echo "PASS: smoke-gui (skipped, as their skip lines say:$skipped)"; else echo "PASS: smoke-gui"; fi
