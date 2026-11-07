#!/bin/sh
# platform: host-agnostic
# usage: sh tests/jtreg-fetch-tries-test.sh
#   build/toolchain.sh's jdk_jtreg_fetch gives every URL of a pinned jtreg dependency but the last 2 tries
#   (SHIPYARD_FETCH_TRIES=2), and the last, or a dependency's only URL, the caller's tries (default 5).
#   That limit must stay with the one attempt: under /bin/sh an assignment prefixed to a function call
#   persists after it, exported. With a stand-in shipyard whose shipyard_fetch_verified logs the tries it
#   sees and fails any URL containing "dead", a dead first URL gets 2, its fallback and every later
#   dependency the default, and SHIPYARD_FETCH_TRIES is still unset afterwards, in the shell and its children.
#   A deps file's TAG line read with a trailing space or CR (a CRLF file) is the TAG it names.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$here/.." && pwd)"
fail() { echo "FAIL $*"; exit 1; }
t="$(mktemp -d "${TMPDIR:-/tmp}/jtreg-fetch-tries.XXXXXX")"
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/repo/build" "$t/repo/components/jtreg" "$t/shipyard"
cp "$REPO/build/toolchain.sh" "$REPO/build/msc.sh" "$t/repo/build/"
printf 'TAG=jtreg-9+9\nSHA256=%s\n' 0000000000000000000000000000000000000000000000000000000000000000 > "$t/repo/components/jtreg/version"
cat > "$t/repo/components/jtreg/deps" <<EOF
TAG=jtreg-9+9
a.zip aaaa https://dead.example/a.zip https://mirror.example/a.zip
b.jar bbbb https://only.example/b.jar
c.txt cccc https://only.example/c.txt
EOF
cat > "$t/shipyard/mavericks_fetch.sh" <<EOF
shipyard_fetch_verified() {
  echo "\$1 \${SHIPYARD_FETCH_TRIES:-default}" >> "$t/log"
  case "\$1" in *dead*) return 1 ;; esac
  mkdir -p "\$3"; : > "\$3/\$4"
}
EOF
unset SHIPYARD_FETCH_TRIES || :
out="$(cd "$t" && MAVERICKS_ROOT="$t/repo" SHIPYARD_SCRIPTS="$t/shipyard" MAVERICKS_BUILD_ROOT="$t/root" /bin/sh -c '
  . "$MAVERICKS_ROOT/build/toolchain.sh"
  mkdir -p "$(jdk_build_root)/jtreg-0000000000000000000000000000000000000000000000000000000000000000/jtreg-jtreg-9-9"
  jdk_jtreg_fetch || exit 9
  echo "shell:${SHIPYARD_FETCH_TRIES:-unset}"
  sh -c "echo child:\${SHIPYARD_FETCH_TRIES:-unset}"' 2>&1)" || fail "jdk_jtreg_fetch failed: $out"
want='https://dead.example/a.zip 2
https://mirror.example/a.zip default
https://only.example/b.jar default
https://only.example/c.txt default'
[ "$(cat "$t/log")" = "$want" ] || fail "tries per fetch were [$(tr '\n' ';' < "$t/log")], not [$(printf '%s' "$want" | tr '\n' ';')]"
printf '%s\n' "$out" | grep -qx 'shell:unset' || fail "SHIPYARD_FETCH_TRIES outlived jdk_jtreg_fetch in its shell: $out"
printf '%s\n' "$out" | grep -qx 'child:unset' || fail "SHIPYARD_FETCH_TRIES reached the shell's children: $out"
printf 'TAG=jtreg-9+9 \r\n' > "$t/crlf"; sed 1d "$t/repo/components/jtreg/deps" >> "$t/crlf"; mv "$t/crlf" "$t/repo/components/jtreg/deps"
: > "$t/log"
out="$(cd "$t" && MAVERICKS_ROOT="$t/repo" SHIPYARD_SCRIPTS="$t/shipyard" MAVERICKS_BUILD_ROOT="$t/root" /bin/sh -c '
  . "$MAVERICKS_ROOT/build/toolchain.sh"; jdk_jtreg_fetch' 2>&1)" || fail "a deps file whose TAG line ends in a space and CR was refused: $out"
echo "PASS: jtreg-fetch-tries"
