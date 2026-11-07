#!/bin/sh
# platform: macOS-only -- runs only on Mac OS X 10.9: installs the pkg with sudo installer and runs it
#   usage: JDK_VERSION=<FULL> sh tests/smoke-mavericks.sh PKG
#          The on-target acceptance for build/package-pkg.sh's jdk-<FULL>.pkg, run on the 10.9 box (it
#          changes the system: it installs over /usr/local/mavergreen/jdk25 and
#          /Library/Java/JavaVirtualMachines/mavergreen-jdk25.jdk). In order:
#            upgrade leg: with a tag in components/previous-release/version, installs that release's
#              pkg (gh release download), checks its manifest version, then installs PKG over it and
#              checks the manifest version and /usr/libexec/java_home -v 25; with none, prints
#              "skip upgrade: no previous release pinned" and installs PKG;
#            the manifest version is JDK_VERSION, and the postinstall wrote lib/server/classes.jsa;
#            the installed keytool -list -cacerts holds the ca-certs-roots that the build-info-jdk25.txt
#              beside PKG records, ISRG Root X1 among them;
#            JDK_HOME=/usr/local/mavergreen/jdk25 sh tests/smoke-runtime.sh --network, where 77 is a
#              failure: on this box the JDK must run;
#            java-25 -version and javac-25 -version from /usr/local/mavergreen/bin;
#            /usr/libexec/java_home -v 25 is the .jdk's Contents/Home, and /usr/bin/java -version
#              reports the installed version;
#            the integration probe: java_home -V, java_home -v 25, /usr/bin/java -version,
#              JAVA_HOME=... /usr/bin/javac -version and JAVA_VERSION=1.6 /usr/bin/java -version (Apple's
#              Java 6, where it is installed), each command, exit status and output appended to
#              $SMOKE_OUT/integration-probe.log (default: the current directory). It records, and
#              asserts nothing yet.
#          Exit 0 when every assertion passes, 1 naming the first that fails, 2 on bad usage, 77 off
#          Mac OS X 10.9 or given neither PKG nor JDK_VERSION (run-repo-tests runs it bare).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"
prefix=/usr/local/mavergreen/jdk25
home=/Library/Java/JavaVirtualMachines/mavergreen-jdk25.jdk/Contents/Home
farm=/usr/local/mavergreen/bin
repo=Mavergreen/jdk-25
fail() { echo "FAIL $*" >&2; exit 1; }

if [ "$#" -eq 0 ] && [ -z "${JDK_VERSION:-}" ]; then
  echo "SKIP smoke-mavericks: no pkg given (usage: JDK_VERSION=<FULL> sh $0 PKG)"; exit 77
fi
[ "$#" -eq 1 ] && [ -n "${JDK_VERSION:-}" ] || { echo "usage: JDK_VERSION=<FULL> sh $0 PKG" >&2; exit 2; }
pkg="$1"
[ -f "$pkg" ] || { echo "smoke-mavericks: no such pkg: $pkg" >&2; exit 2; }
if [ "$(uname -s)" != Darwin ] || [ "$(uname -r | cut -d. -f1)" != 13 ]; then
  echo "SKIP smoke-mavericks: this is not Mac OS X 10.9"; exit 77
fi
out="${SMOKE_OUT:-$(pwd)}"
probe="$out/integration-probe.log"
work="$(mktemp -d "${TMPDIR:-/tmp}/smoke-mavericks.XXXXXX")"
trap 'rm -rf "$work"' EXIT

install_pkg() {
  echo "== sudo installer -pkg $1 -target /"
  sudo installer -pkg "$1" -target / || fail "installer refused $1"
}
installed_version() { /usr/libexec/PlistBuddy -c 'Print :version' "$prefix/mavergreen.plist" 2>/dev/null || true; }

# spec: PORT.md ruling R52 -- the leg runs once the pin
#       names a released tag, and says it skipped until then.
prev="$(tr -d '[:space:]' < "$MAVERICKS_ROOT/components/previous-release/version" 2>/dev/null || true)"
case "$prev" in
  ''|none)
    echo "skip upgrade: no previous release pinned"
    install_pkg "$pkg" ;;
  *)
    command -v gh > /dev/null 2>&1 || fail "the upgrade leg needs gh to fetch $repo $prev"
    mkdir "$work/prev"
    gh release download "$prev" -R "$repo" --pattern 'jdk-*.pkg' -D "$work/prev" \
      || fail "could not download $repo release $prev"
    set -- "$work/prev"/jdk-*.pkg
    [ -f "$1" ] || fail "release $prev has no jdk-*.pkg asset"
    [ "$#" -eq 1 ] || fail "release $prev has $# jdk-*.pkg assets, not one"
    install_pkg "$1"
    [ "$(installed_version)" = "$prev" ] || fail "after installing $prev the manifest says $(installed_version)"
    install_pkg "$pkg"
    [ "$(installed_version)" = "$JDK_VERSION" ] || fail "the upgrade from $prev left version $(installed_version), not $JDK_VERSION"
    jh="$(/usr/libexec/java_home -v 25 2>/dev/null)" || fail "after the upgrade from $prev, java_home -v 25 finds nothing"
    [ "$jh" = "$home" ] || fail "after the upgrade from $prev, java_home -v 25 is $jh, not $home"
    echo "ok upgrade: $prev to $JDK_VERSION, java_home -v 25 is $home" ;;
esac

[ "$(installed_version)" = "$JDK_VERSION" ] || fail "the installed manifest version is '$(installed_version)', not $JDK_VERSION"
echo "ok manifest: $JDK_VERSION"
# spec: PORT.md ruling R28 -- the postinstall writes the archive
[ -s "$prefix/lib/server/classes.jsa" ] \
  || fail "the postinstall wrote no $prefix/lib/server/classes.jsa; /var/log/install.log says why"
echo "ok cds: $prefix/lib/server/classes.jsa"
# spec: PORT.md ruling R18 -- build-jdk-test's runtime half runs here, on the installed JDK, since no
#       runner executes x86_64; smoke-runtime's required headless check covers the headless default
bi="$(dirname "$pkg")/build-info-jdk25.txt"
roots="$(sed -n 's/^ca-certs-roots=//p' "$bi" 2>/dev/null)"
case "$roots" in ''|*[!0-9]*) fail "$bi records no ca-certs-roots=<count> (package-pkg.sh writes it beside the pkg)" ;; esac
"$prefix/bin/keytool" -list -cacerts < /dev/null > "$work/cacerts" 2>&1 \
  || { cat "$work/cacerts" >&2; fail "the installed keytool -list -cacerts failed"; }
grep -q "^Your keystore contains $roots entries\$" "$work/cacerts" \
  || fail "the installed keytool -list -cacerts: $(grep '^Your keystore contains' "$work/cacerts" || echo 'no count'), not $roots"
# platform: ISRG Root X1 (SHA-1 CA:BD:2A:79:...), Let's Encrypt's root; a file name's alias is lowercase
grep -q '^cabd2a79a1076a31f21d253635cb039d4329a5e8\.pem \[jdk\],' "$work/cacerts" \
  || fail "the installed cacerts has no ISRG Root X1 (cabd2a79a1076a31f21d253635cb039d4329a5e8.pem [jdk])"
echo "ok cacerts: $roots roots, ISRG Root X1 among them"

rc=0
JDK_HOME="$prefix" sh "$here/smoke-runtime.sh" --network || rc=$?
[ "$rc" -eq 0 ] || fail "smoke-runtime --network exited $rc (77, cannot execute, is a failure on this box)"
echo "ok smoke-runtime --network"

for t in java javac; do
  [ -x "$farm/$t-25" ] || fail "$farm/$t-25 is not installed"
  v="$("$farm/$t-25" -version 2>&1)" || fail "$farm/$t-25 -version failed: $v"
  echo "ok $t-25 -version: $(printf '%s\n' "$v" | sed -n 1p)"
done

# spec: PORT.md ruling R44 -- the system's java_home and
#       /usr/bin/java find the .jdk
jh="$(/usr/libexec/java_home -v 25 2>/dev/null)" || fail "java_home -v 25 finds nothing"
[ "$jh" = "$home" ] || fail "java_home -v 25 is $jh, not $home"
echo "ok java_home -v 25: $home"
jver="${JDK_VERSION%-mavericks.*}"; jrev="${JDK_VERSION#"$jver"-}"
v="$(/usr/bin/java -version 2>&1)" || fail "/usr/bin/java -version failed: $v"
case "$v" in
  *"version \"$jver\""*"+"*"-$jrev)"*) ;;
  *) fail "/usr/bin/java -version is not $JDK_VERSION: $v" ;;
esac
echo "ok /usr/bin/java -version: $(printf '%s\n' "$v" | sed -n 1p)"

{
  echo "# integration probe, $(date -u '+%Y-%m-%dT%H:%M:%SZ'), $JDK_VERSION"
  for c in "/usr/libexec/java_home -V" "/usr/libexec/java_home -v 25" "/usr/bin/java -version" \
    "JAVA_HOME=$home /usr/bin/javac -version" "JAVA_VERSION=1.6 /usr/bin/java -version"; do
    echo "\$ $c"
    _prc=0
    _pout="$(eval "$c" 2>&1)" || _prc=$?
    printf '%s\n' "$_pout"
    echo "[exit $_prc]"
  done
} >> "$probe"
echo "ok integration probe recorded in $probe"
echo "PASS: smoke-mavericks $JDK_VERSION"
