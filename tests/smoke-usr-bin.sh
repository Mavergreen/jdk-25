#!/bin/sh
# platform: macOS-only -- Mac OS X 10.9's /usr/bin Java stubs, java_home and Jar Launcher; off 10.9 only with stand-ins
#   usage: sh tests/smoke-usr-bin.sh HOME JVER JREV
#          The /usr/bin half of tests/smoke-mavericks.sh (PORT.md ruling R60): with JAVA_HOME and
#          JAVA_VERSION unset, so the stubs choose as a user's shell would, it asserts
#            java_home -V lists "Mavericks JDK 25" at HOME, and java_home -v 25 is HOME;
#            /usr/bin/java -version reports version "JVER" ... -JREV);
#            /usr/bin/javac -version and /usr/bin/jar --version report JVER, and they compile and jar a
#              Main-Class jar, which /usr/bin/java -jar runs: it writes a marker holding java.version;
#            $(java_home -v 25)/bin/jshell evaluates 6*7 (Apple never shipped /usr/bin/jshell);
#            JAVA_HOME=$(java_home -v 25) /usr/bin/java -version reports JVER;
#            open -a "Jar Launcher" on that jar, the double-click equivalent, writes its marker within
#              SMOKE_JAR_WAIT seconds (default 60), or prints "skipped: no window server" when the
#              console (stat -f %Su /dev/console) is not this user's: open -a needs this user's GUI login;
#            none of those printed Apple's "No Java runtime present, requesting install." on stderr,
#              and no Java Updater or Install*.app process appeared meanwhile (PackageKit's installd,
#              always running, is not one).
#          SMOKE_USR_BIN, SMOKE_JAVA_HOME_TOOL, SMOKE_CONSOLE, SMOKE_OPEN, SMOKE_PS and SMOKE_JAR_LAUNCHER
#          replace /usr/bin, /usr/libexec/java_home, /dev/console, /usr/bin/open, /bin/ps and
#          "Jar Launcher", so tests/smoke-usr-bin-test.sh runs it off 10.9.
#          Exit 0 when every assertion passes, 1 naming the first that fails, 2 on bad usage, 77 when
#          given no arguments (run-repo-tests runs it bare) or this host's CPU does not run HOME natively.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then echo "SKIP smoke-usr-bin: no JDK given (usage: sh $0 HOME JVER JREV)"; exit 77; fi
[ "$#" -eq 3 ] || { echo "usage: sh $0 HOME JVER JREV" >&2; exit 2; }
home="$1"; jver="$2"; jrev="$3"
usrbin="${SMOKE_USR_BIN:-/usr/bin}"
jhtool="${SMOKE_JAVA_HOME_TOOL:-/usr/libexec/java_home}"
console="${SMOKE_CONSOLE:-/dev/console}"
opener="${SMOKE_OPEN:-/usr/bin/open}"
pscmd="${SMOKE_PS:-/bin/ps}"
launcher="${SMOKE_JAR_LAUNCHER:-Jar Launcher}"
wait="${SMOKE_JAR_WAIT:-60}"
fail() { echo "FAIL $*" >&2; exit 1; }

# spec: PORT.md ruling R18 -- the JDK the stubs dispatch to runs only where this CPU runs it untranslated
. "$here/lib/host-cpu.sh"
jdk_runs_natively "$home" || { echo "SKIP: this host's CPU does not run the JDK at $home natively (PORT.md ruling R18)"; exit 77; }
unset JAVA_HOME JAVA_VERSION
work="$(mktemp -d "${TMPDIR:-/tmp}/smoke-usr-bin.XXXXXX")"
trap 'rm -rf "$work"' EXIT
case "$work" in *[\\\"]*) fail "the work directory $work has a quote or backslash, which Hello.java cannot hold" ;; esac

# platform: ps -o comm= is the executable's path without arguments, so an argument naming an app
#           (a renderer's --disable-features=InstalledApp) never counts; 10.9's stubs ask for Java
#           through Java Updater.app or an Install*.app, and PackageKit's installd is neither
prompts() { "$pscmd" -axo comm= | grep -E '/Java Updater\.app/|/Install[^/]*\.app/' | sort -u || true; }
prompts > "$work/before"
noprompt() {
  if grep -E 'No Java runtime present|requesting install' "$work/err" > /dev/null; then
    fail "$1 asked to install Java: $(cat "$work/err")"
  fi
}
ours() {
  case "$2" in
    *"version \"$jver\""*"+"*"-$jrev)"*) ;;
    *) fail "$1 does not report $jver (-$jrev): $2" ;;
  esac
}

v="$("$jhtool" -V 2>&1)" || fail "java_home -V failed: $v"
printf '%s\n' "$v" | grep -F '"Mavericks JDK 25"' | grep -F "$home" > /dev/null \
  || fail "java_home -V does not list \"Mavericks JDK 25\" at $home: $v"
echo "ok java_home -V lists \"Mavericks JDK 25\""
jh="$("$jhtool" -v 25 2> /dev/null)" || fail "java_home -v 25 finds nothing"
[ "$jh" = "$home" ] || fail "java_home -v 25 is $jh, not $home"

"$usrbin/java" -version > "$work/out" 2> "$work/err" || fail "$usrbin/java -version failed: $(cat "$work/err")"
noprompt "$usrbin/java -version"
ours "$usrbin/java -version" "$(cat "$work/out" "$work/err")"
echo "ok $usrbin/java -version: $(sed -n 1p "$work/err")"

"$usrbin/javac" -version > "$work/out" 2> "$work/err" || fail "$usrbin/javac -version failed: $(cat "$work/err")"
noprompt "$usrbin/javac -version"
[ "$(cat "$work/out" "$work/err")" = "javac $jver" ] || fail "$usrbin/javac -version is not javac $jver: $(cat "$work/out" "$work/err")"
"$usrbin/jar" --version > "$work/out" 2> "$work/err" || fail "$usrbin/jar --version failed: $(cat "$work/err")"
noprompt "$usrbin/jar --version"
[ "$(cat "$work/out" "$work/err")" = "jar $jver" ] || fail "$usrbin/jar --version is not jar $jver: $(cat "$work/out" "$work/err")"

mkdir "$work/src" "$work/classes"
cat > "$work/src/Hello.java" <<EOF
import java.nio.file.*;
public class Hello {
  public static void main(String[] a) throws Exception {
    Path m = Paths.get(a.length > 0 ? a[0] : "$work/gui.marker");
    Path t = Paths.get(m + ".tmp");
    Files.write(t, System.getProperty("java.version").getBytes("UTF-8"));
    Files.move(t, m, StandardCopyOption.ATOMIC_MOVE);
  }
}
EOF
"$usrbin/javac" -d "$work/classes" "$work/src/Hello.java" > "$work/out" 2> "$work/err" \
  || fail "$usrbin/javac could not compile Hello.java: $(cat "$work/out" "$work/err")"
noprompt "$usrbin/javac"
"$usrbin/jar" --create --file "$work/hello.jar" --main-class Hello -C "$work/classes" . > "$work/out" 2> "$work/err" \
  || fail "$usrbin/jar could not make hello.jar: $(cat "$work/out" "$work/err")"
noprompt "$usrbin/jar"
"$usrbin/java" -jar "$work/hello.jar" "$work/cli.marker" > "$work/out" 2> "$work/err" \
  || fail "$usrbin/java -jar hello.jar failed: $(cat "$work/out" "$work/err")"
noprompt "$usrbin/java -jar"
[ "$(cat "$work/cli.marker" 2> /dev/null)" = "$jver" ] \
  || fail "$usrbin/java -jar hello.jar ran java.version '$(cat "$work/cli.marker" 2> /dev/null)', not $jver"
echo "ok $usrbin/javac and $usrbin/jar: $jver, and $usrbin/java -jar ran the jar"

printf 'System.out.println(6*7);\n/exit\n' > "$work/s.jsh"
out="$("$jh/bin/jshell" -q "$work/s.jsh" < /dev/null 2>&1)" || fail "$jh/bin/jshell failed: $out"
[ "$out" = 42 ] || fail "$jh/bin/jshell printed '$out' for 6*7, not 42"
echo "ok \$(java_home -v 25)/bin/jshell: 6*7 is 42"

JAVA_HOME="$jh" "$usrbin/java" -version > "$work/out" 2> "$work/err" \
  || fail "JAVA_HOME=$jh $usrbin/java -version failed: $(cat "$work/err")"
noprompt "JAVA_HOME=$jh $usrbin/java -version"
ours "JAVA_HOME=$jh $usrbin/java -version" "$(cat "$work/out" "$work/err")"
echo "ok JAVA_HOME=\$(java_home -v 25) $usrbin/java -version"

owner="$(stat -f %Su "$console" 2> /dev/null || true)"
if [ "$owner" != "$(id -un)" ]; then
  echo "skipped: no window server: the console belongs to ${owner:-nobody}, not $(id -un), so open -a \"$launcher\" cannot run"
else
  "$opener" -a "$launcher" "$work/hello.jar" > "$work/out" 2>&1 \
    || fail "open -a \"$launcher\" hello.jar failed: $(cat "$work/out")"
  i=0
  while [ ! -f "$work/gui.marker" ] && [ "$i" -lt "$wait" ]; do sleep 1; i=$((i + 1)); done
  [ -f "$work/gui.marker" ] || fail "open -a \"$launcher\" hello.jar wrote no marker within $wait s"
  [ "$(cat "$work/gui.marker")" = "$jver" ] \
    || fail "open -a \"$launcher\" ran hello.jar under java.version '$(cat "$work/gui.marker")', not $jver"
  echo "ok open -a \"$launcher\" hello.jar ran it under $jver (${i} s)"
fi

# platform: a stub starts its installer apart from itself, so give one a moment to appear
sleep 2
prompts > "$work/after"
new="$(comm -13 "$work/before" "$work/after")"
[ -z "$new" ] || fail "an installer appeared while the stubs ran: $new"
echo "ok no Java Updater or Install process appeared"
echo "PASS: smoke-usr-bin"
