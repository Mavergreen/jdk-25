#!/bin/sh
# platform: macOS-only -- needs this user's Aqua session (a console login) to open windows
#   usage: JDK_HOME=<dir> sh tests/smoke-gui.sh
#          Compiles tests/java/GuiSmoke.java with JDK_HOME's javac and runs it with JDK_HOME's java,
#          without -Djava.awt.headless, so the JDK's own default decides (gui: headful in an Aqua
#          session). It requires an "ok <step>" line for each of: headful frame menubar paint pixel
#          resize fullscreen type close. Exit 0 when all pass, 1 naming each failed step on stderr,
#          77 when JDK_HOME is unset (run-repo-tests runs this bare), JDK_HOME/bin/java is not
#          executable, this host's CPU does not run the JDK natively, or there is no window server:
#          /dev/console (SMOKE_CONSOLE) does not belong to this user, as tests/smoke-usr-bin.sh decides.
#          GuiSmoke stops itself after 180 s; SMOKE_GUI_SECONDS (default 240) bounds the whole run.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
steps="headful frame menubar paint pixel resize fullscreen type close"
fail=0
bad() { echo "FAIL $1: $2" >&2; fail=1; }

if [ -z "${JDK_HOME:-}" ]; then
  echo "SKIP smoke-gui: JDK_HOME is unset (usage: JDK_HOME=<dir> sh $0)"; exit 77
fi
java="$JDK_HOME/bin/java"
[ -x "$java" ] || { echo "SKIP smoke-gui: $java is not executable"; exit 77; }
# spec: PORT.md ruling R18 -- decided by the host's CPU, never by trying: under Rosetta it would run
. "$here/lib/host-cpu.sh"
jdk_runs_natively "$JDK_HOME" || { echo "SKIP smoke-gui: this host's CPU does not run the JDK at $JDK_HOME natively (PORT.md ruling R18)"; exit 77; }
# spec: PORT.md ruling R60 -- a window needs this user's Aqua session, which the console's owner has
owner="$(stat -f %Su "${SMOKE_CONSOLE:-/dev/console}" 2> /dev/null || true)"
if [ "$owner" != "$(id -un)" ]; then
  msg="SKIP smoke-gui: no window server: the console belongs to ${owner:-nobody}, not $(id -un), so no window can open; nothing headful was tested"
  echo "$msg"; echo "$msg" >&2
  exit 77
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/smoke-gui.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 1' HUP INT TERM
"$JDK_HOME/bin/javac" -d "$T/classes" "$here/java/GuiSmoke.java" > "$T/javac.out" 2>&1 \
  || { cat "$T/javac.out" >&2; echo "FAIL compile: javac could not compile tests/java/GuiSmoke.java" >&2; exit 1; }

prc=0
"$java" -cp "$T/classes" GuiSmoke > "$T/smoke.out" 2>&1 < /dev/null &
pid=$!
(sleep "${SMOKE_GUI_SECONDS:-240}"; kill -9 "$pid" 2> /dev/null) > /dev/null 2>&1 &
guard=$!
wait "$pid" || prc=$?
kill "$guard" 2> /dev/null || true
cat "$T/smoke.out"
for n in $(sed -n 's/^FAIL \([A-Za-z0-9_]*\):.*/\1/p' "$T/smoke.out"); do
  bad "$n" "reported by GuiSmoke: $(grep "^FAIL $n:" "$T/smoke.out" | head -1)"
done
for n in $steps; do
  grep -q "^ok $n\$" "$T/smoke.out" || bad "$n" "no ok line from GuiSmoke"
done
[ "$prc" -eq 0 ] || bad exit "GuiSmoke exited $prc"
[ "$fail" -eq 0 ] || exit 1
echo "PASS: smoke-gui"
