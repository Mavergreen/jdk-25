#!/bin/sh
# platform: host-agnostic
# usage: JDK_HOME=<dir> sh tests/smoke-runtime.sh [--network]
#   Compiles and runs tests/java/LegacySmoke.java with JDK_HOME's own javac and java, then runs jshell,
#   jlink and --version over JDK_HOME/bin. Exit 0 when every check passes, 1 naming each failed check
#   on stderr, 2 on bad usage, 77 when JDK_HOME is unset (nothing to smoke: run-repo-tests runs this
#   bare), JDK_HOME/bin/java is not executable, or the JDK is of a CPU this host does not run natively
#   (tests/lib/host-cpu.sh's jdk_runs_natively, by its release file's OS_ARCH or bin/java read through
#   symlinks: an x86_64 JDK on an arm64 Mac, Rosetta or not), decided without running it.
#   --network adds an HttpClient GET of https://github.com (needs the network).
#   SMOKE_STOCK_JDK=1 passes -Djava.awt.headless=true to the program, for validating this test against
#   upstream JDK builds only; our builds default to headless and must be run without it.
#   --version is required of the tools listed in known_tools (the launchers the JDK 25 man pages
#   document with --version); any other bin/* is tried and skipped if it rejects --version and -version.
#   Each --version probe is stopped after SMOKE_TOOL_SECONDS (default 20): a listed tool that runs
#   longer fails, any other is skipped (a GUI JDK's jconsole opens a window instead of answering).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
known_tools="java javac javadoc jar javap jdeps jlink jmod jshell"
required="clocks fileCopy zip udp tcp urgentData tls process headless fonts"

network=no
for a in "$@"; do
  case "$a" in
    --network) network=yes ;;
    *) echo "usage: JDK_HOME=<dir> sh $0 [--network]" >&2; exit 2 ;;
  esac
done
if [ -z "${JDK_HOME:-}" ]; then
  echo "SKIP smoke-runtime: JDK_HOME is unset (usage: JDK_HOME=<dir> sh $0 [--network])"; exit 77
fi
if [ "$network" = yes ]; then required="$required https"; fi

failed=""
good() { echo "ok $1"; }
tool_seconds="${SMOKE_TOOL_SECONDS:-20}"
bounded() {  # bounded CMD...: CMD's exit status, or 124 once it outlives tool_seconds (then killed)
  "$@" > /dev/null 2>&1 < /dev/null &
  bpid=$!
  (trap 'kill "$bsleep" 2> /dev/null; exit 0' TERM
   sleep "$tool_seconds" & bsleep=$!; wait "$bsleep"
   kill "$bpid" 2> /dev/null && : > "$T/timed-out") > /dev/null 2>&1 &
  bdog=$!
  brc=0; wait "$bpid" || brc=$?
  kill "$bdog" 2> /dev/null || true; wait "$bdog" 2> /dev/null || true
  if [ -e "$T/timed-out" ]; then rm -f "$T/timed-out"; return 124; fi
  return "$brc"
}
probe() {  # probe TOOL: 0 if TOOL answers --version or -version, 124 if it hangs, else 1
  prc=0; bounded "$1" --version || prc=$?
  [ "$prc" = 0 ] && return 0
  [ "$prc" = 124 ] && return 124
  prc=0; bounded "$1" -version || prc=$?
  [ "$prc" = 0 ] && return 0
  [ "$prc" = 124 ] && return 124
  return 1
}
bad() { echo "FAIL $1: $2" >&2; failed="$failed $1"; }

java="$JDK_HOME/bin/java"
if [ ! -x "$java" ]; then
  echo "SKIP: $java is not executable"; exit 77
fi
# spec: PORT.md ruling R18 -- decided by the host's CPU, never by trying: under Rosetta it would run
. "$here/lib/host-cpu.sh"
jdk_runs_natively "$JDK_HOME" || { echo "SKIP: this host's CPU does not run the JDK at $JDK_HOME natively (PORT.md ruling R18)"; exit 77; }
jrc=0
"$java" -version > /dev/null 2>&1 || jrc=$?
[ "$jrc" = 0 ] || { echo "FAIL java-version: $java -version exited $jrc" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/smoke-runtime.XXXXXX")"
trap 'rm -rf "$T"' EXIT
trap 'exit 1' HUP INT TERM

if "$JDK_HOME/bin/javac" -d "$T/classes" "$here/java/LegacySmoke.java" > "$T/javac.out" 2>&1; then
  good compile
  set -- -cp "$T/classes" "-Djava.io.tmpdir=${TMPDIR:-/tmp}"
  if [ "${SMOKE_STOCK_JDK:-}" = 1 ]; then set -- "$@" -Djava.awt.headless=true; fi
  set -- "$@" LegacySmoke
  if [ "$network" = yes ]; then set -- "$@" --network; fi
  prc=0
  "$java" "$@" > "$T/smoke.out" 2>&1 < /dev/null || prc=$?
  cat "$T/smoke.out"
  flagged=no
  for n in $(sed -n 's/^FAIL \([A-Za-z0-9_]*\):.*/\1/p' "$T/smoke.out"); do
    bad "$n" "reported by LegacySmoke: $(grep "^FAIL $n:" "$T/smoke.out" | head -1)"
    flagged=yes
  done
  for n in $required; do
    if ! grep -q "^ok $n\$" "$T/smoke.out" && ! grep -q "^FAIL $n:" "$T/smoke.out"; then
      bad "$n" "no ok line from LegacySmoke"; flagged=yes
    fi
  done
  if [ "$prc" != 0 ] && [ "$flagged" = no ]; then
    bad smoke "LegacySmoke exited $prc with no FAIL line"
  fi
else
  cat "$T/javac.out" >&2
  bad compile "javac could not compile tests/java/LegacySmoke.java"
fi

printf 'System.out.println(6*7)\n/exit\n' > "$T/smoke.jsh"
jout="$("$JDK_HOME/bin/jshell" -s "$T/smoke.jsh" 2>&1 < /dev/null)" || true
if printf '%s\n' "$jout" | grep -qx 42; then good jshell; else bad jshell "expected 42, got: $jout"; fi

if "$JDK_HOME/bin/jlink" --add-modules java.base --output "$T/image" > "$T/jlink.out" 2>&1; then
  if "$T/image/bin/java" -version > /dev/null 2>&1 \
     && "$T/image/bin/java" --list-modules 2> /dev/null | grep -q '^java.base'; then
    good jlink
  else
    bad jlink "the linked image does not run or lacks java.base"
  fi
else
  bad jlink "jlink --add-modules java.base failed: $(cat "$T/jlink.out")"
fi

for t in $known_tools; do
  p="$JDK_HOME/bin/$t"
  if [ ! -x "$p" ]; then bad "version-$t" "absent from $JDK_HOME/bin"; continue; fi
  vrc=0; probe "$p" || vrc=$?
  case "$vrc" in
    0) good "version-$t" ;;
    124) bad "version-$t" "did not exit within ${tool_seconds}s of --version or -version" ;;
    *) bad "version-$t" "rejects --version and -version" ;;
  esac
done
for p in "$JDK_HOME"/bin/*; do
  t="$(basename "$p")"
  case " $known_tools " in *" $t "*) continue ;; esac
  [ -x "$p" ] || continue
  vrc=0; probe "$p" || vrc=$?
  case "$vrc" in
    0) good "version-$t" ;;
    124) echo "skip version-$t (did not exit within ${tool_seconds}s of --version or -version)" ;;
    *) echo "skip version-$t (rejects --version and -version)" ;;
  esac
done

if [ -n "$failed" ]; then
  echo "FAIL:$failed" >&2; exit 1
fi
echo "PASS smoke-runtime"
