#!/bin/sh
# platform: host-agnostic
# usage: sh tests/pin-jtreg-test.sh
#   scripts/pin-jtreg.sh moves components/jtreg/version to the jtreg the pinned jdk source's own CI runs
#   (JTREG_VERSION in make/conf/github-actions.conf at DIGEST; ruling R48): TAG=jtreg-<that version> and
#   SHA256, the SHA-256 of GitHub's tarball of TAG, written only for a tarball that holds exactly the
#   tag's commit's files. With the pin already that jtreg it writes nothing and fetches no tarball;
#   --check writes nothing and exits 3 when the pin is another jtreg. A JTREG_VERSION of the wrong shape,
#   a conf that names none, a tag jtreg does not have, or a tarball that is not its tag's tree is refused
#   with exit 1, writing nothing. Exits, which the pins bot relies on: 0 current (or written), 3 stale
#   (--check), 1 any failure, 2 usage.
#   Offline: a fixture git repository stands in for openjdk/jtreg, file:// trees serve the conf and its
#   tarball (made as GitHub makes it), and a fake shipyard clones the fixture.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
# platform: OS X 10.9's /usr/bin/git is a Command Line Tools stub, there whether or not they are installed.
git --version >/dev/null 2>&1 || { echo "no git that runs -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pin-jtreg.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
REAL_SHIPYARD="$(. "$REPO/build/msc.sh" 2>/dev/null && echo "$SHIPYARD")" || { echo "no shipyard -- skipping"; exit 77; }
R="$T/repo"; mkdir -p "$R/scripts" "$R/build" "$R/components/jdk" "$R/components/jtreg" "$T/shipyard" "$T/tmp"
cp "$REAL_SHIPYARD/mavericks_fetch.sh" "$T/shipyard/"   # shipyard_curl
cp "$REPO/scripts/pin-jtreg.sh" "$R/scripts/"; cp "$REPO/build/msc.sh" "$R/build/"
D=1111111111111111111111111111111111111111
printf 'REPO=https://github.com/openjdk/jdk25u\nGA=jdk-25.0.9-ga\nREF=jdk-25.0.9+9\nDIGEST=%s\nTARBALL_SHA256=%s\n' \
  "$D" 0000000000000000000000000000000000000000000000000000000000000000 > "$R/components/jdk/version"
J="$R/components/jtreg/version"
OLD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf 'TAG=jtreg-8.2.1+1\nSHA256=%s\n' "$OLD" > "$J"
printf 'TAG=jtreg-8.2.1+1\nsome deps\n' > "$R/components/jtreg/deps"
cp "$R/components/jtreg/deps" "$T/deps"
g="$T/up/jtreg"; mkdir -p "$g/make"
git -C "$g" init -q; git -C "$g" config user.email t@t; git -C "$g" config user.name t
echo old > "$g/make/version-numbers"; git -C "$g" add -A; git -C "$g" commit -qm old; git -C "$g" tag jtreg-8.2.1+1
echo new > "$g/make/version-numbers"; git -C "$g" commit -qam new; git -C "$g" tag -a -m 8.3 'jtreg-8.3+1'
NEWTAG='jtreg-8.3+1'
arch="$T/gh/openjdk/jtreg/archive/refs/tags"; mkdir -p "$arch"
tarball() {  # tarball [<shell run in the tree before packing>]: GitHub's tarball of NEWTAG
  rm -rf "$T/fake"; mkdir -p "$T/fake"
  git -C "$g" archive --format=tar --prefix=jtreg-jtreg-8.3-1/ "$NEWTAG" | tar xf - -C "$T/fake"
  ( cd "$T/fake/jtreg-jtreg-8.3-1" && eval "${1:-true}" )
  ( cd "$T/fake" && tar cf - jtreg-jtreg-8.3-1 | gzip -n > "$arch/$NEWTAG.tar.gz" )
}
tarball
conf="$T/raw/openjdk/jdk25u/$D/make/conf"; mkdir -p "$conf"
setconf() { printf 'JTREG_MIN_VERSION=8\nJTREG_VERSION=%s\nGTEST_VERSION=1.14.0\n' "$1" > "$conf/github-actions.conf"; }
cat > "$T/shipyard/clone_pinned.sh" <<F
#!/bin/sh
git clone -q "$g" "\$4" && git -C "\$4" checkout -q "\$3" && [ "\$(git -C "\$4" rev-parse HEAD)" = "\$3" ]
F
pins() {
  TMPDIR="$T/tmp" SHIPYARD_SCRIPTS="$T/shipyard" PIN_JTREG_RAW="file://$T/raw" PIN_JTREG_GITHUB="file://$T/gh" \
    PIN_JTREG_REPO="$g" sh "$R/scripts/pin-jtreg.sh" "$@"
}
run() { rc=0; pins "$@" > "$T/out" 2>&1 || rc=$?; }
want() { [ "$rc" = "$1" ] || fail "$2: exit $rc, not $1: $(cat "$T/out")"; }
sum() { shasum -a 256 < "$arch/$NEWTAG.tar.gz" | cut -c1-64; }
left() { ls -A "$T/tmp"; ls -A "$R/components/jtreg" | grep -vx -e version -e deps || true; }
cp "$J" "$T/before"

echo "-- usage: exit 2, nothing written"
for a in --bogus "--check --check" "--check extra"; do
  # shellcheck disable=SC2086  # the words are the arguments
  run $a; want 2 "usage [$a]"
  grep -q "^usage: " "$T/out" || fail "usage [$a] printed: $(cat "$T/out")"
done
cmp -s "$T/before" "$J" || fail "a usage error wrote the pin file"

echo "-- the same jtreg: current, nothing fetched or written"
setconf 8.2.1+1
mv "$arch/$NEWTAG.tar.gz" "$T/away.tar.gz"
run --check; want 0 "--check, the conf naming the pinned jtreg"
run; want 0 "a write, the conf naming the pinned jtreg"
cmp -s "$T/before" "$J" || fail "the same jtreg: the pin file changed"
mv "$T/away.tar.gz" "$arch/$NEWTAG.tar.gz"

echo "-- another jtreg: --check 3 writing nothing; a write moves TAG and SHA256 and nothing else"
setconf 8.3+1
run --check; want 3 "--check, the conf naming another jtreg"
grep -qF "jtreg-8.2.1+1" "$T/out" && grep -qF "$NEWTAG" "$T/out" || fail "--check did not name both: $(cat "$T/out")"
cmp -s "$T/before" "$J" || fail "--check wrote the pin file"
run; want 0 "a write"
[ "$(cat "$J")" = "TAG=$NEWTAG
SHA256=$(sum)" ] || fail "the pin file: $(cat "$J")"
cmp -s "$T/deps" "$R/components/jtreg/deps" || fail "pin-jtreg.sh wrote the deps file, which is pin-jtreg-deps.sh's"
[ -z "$(left)" ] || fail "a write left $(left)"
run --check; want 0 "--check after the write"

echo "-- refused, exit 1, nothing written: a malformed or missing JTREG_VERSION, a tag jtreg lacks, a tarball not its tag's tree"
for v in "" latest "8.3" "8.3+1;touch $T/pwned" "8.3+1 x" "../8+1"; do
  cp "$T/before" "$J"; setconf "$v"
  for mode in "" --check; do
    # shellcheck disable=SC2086  # "" is no argument
    run $mode; want 1 "JTREG_VERSION '$v' ${mode:-write}"
    cmp -s "$T/before" "$J" || fail "JTREG_VERSION '$v': wrote the pin file"
  done
done
[ ! -e "$T/pwned" ] || fail "a JTREG_VERSION ran"
grep -v JTREG_VERSION "$conf/github-actions.conf" > "$T/c" && cp "$T/c" "$conf/github-actions.conf"
run --check; want 1 "a conf with no JTREG_VERSION"
printf 'JTREG_VERSION=8.3+1\nJTREG_VERSION=8.2.1+1\n' > "$conf/github-actions.conf"
for mode in "" --check; do
  # shellcheck disable=SC2086  # "" is no argument
  run $mode; want 1 "a conf with two JTREG_VERSION lines ${mode:-write}"
  grep -q "more than one JTREG_VERSION" "$T/out" || fail "two JTREG_VERSION lines: $(cat "$T/out")"
  cmp -s "$T/before" "$J" || fail "two JTREG_VERSION lines: wrote the pin file"
done
setconf 9.9+9
run; want 1 "a jtreg tag that does not exist"
cmp -s "$T/before" "$J" || fail "a tag that does not exist: wrote the pin file"
setconf 8.3+1
for m in 'echo tampered > make/version-numbers' 'mkdir empty' 'mkdir -p .git && echo x > .git/x'; do
  tarball "$m"
  run; want 1 "a tarball not its tag's tree [$m]"
  grep -q "is not $NEWTAG's tree" "$T/out" || fail "[$m]: $(cat "$T/out")"
  cmp -s "$T/before" "$J" || fail "[$m]: wrote the pin file"
  [ -z "$(left)" ] || fail "[$m] left $(left)"
done
tarball
rm "$conf/github-actions.conf"
run --check; want 1 "an unfetchable conf"
cmp -s "$T/before" "$J" || fail "an unfetchable conf: wrote the pin file"
echo "PASS"
