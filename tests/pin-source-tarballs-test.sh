#!/bin/sh
# platform: host-agnostic
# usage: sh tests/pin-source-tarballs-test.sh
#   scripts/pin-source-tarballs.sh must write into components/jdk/version the SHA-256 of the pinned
#   commit's tarball, leaving every other line as it was; with --check, write nothing and fail naming a
#   pin that is not its tarball's; and refuse, writing nothing, a tarball that does not hold exactly its
#   commit's files -- a changed byte, a .git anywhere (a directory or a gitdir file), an empty directory,
#   a name that differs only in case. The file is written once, after the tarball is verified: any
#   failure, or a TERM, leaves it byte for byte as it was and leaves no temp file behind. Its exits,
#   which the pins bot relies on: 0 current (or written), 3 stale (--check), 1 any failure (a refused
#   tarball, a failed fetch, a bad digest, an unset pin, a git failure), 2 usage, 143 TERM.
#   Offline: a fixture git repository stands in for jdk25u, a fake shipyard serves its tarball (made as
#   GitHub makes it, `git archive --prefix=<name>-<commit>/`) and clones it, and a copy of the pin file
#   names the fixture's commit.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
# platform: OS X 10.9's /usr/bin/git is a Command Line Tools stub, there whether or not they are installed.
git --version >/dev/null 2>&1 || { echo "no git that runs -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pin-source-tarballs.XXXXXX")"
trap 'rm -rf "$T"' EXIT
T="$(CDPATH='' cd -P -- "$T" && pwd -P)"
REAL_SHIPYARD="$(. "$REPO/build/msc.sh" 2>/dev/null && echo "$SHIPYARD")" || { echo "no shipyard -- skipping"; exit 77; }
R="$T/repo"; mkdir -p "$R/scripts" "$R/build" "$R/components/jdk" "$T/shipyard" "$T/tarballs" "$T/tmp"
cp "$REAL_SHIPYARD/mavericks_fetch.sh" "$T/shipyard/"   # shipyard_curl
cp "$REPO/scripts/pin-source-tarballs.sh" "$R/scripts/"; cp "$REPO/build/msc.sh" "$R/build/"
n=jdk25u
g="$T/up/$n"; mkdir -p "$g/sub"
git -C "$g" init -q; git -C "$g" config user.email t@t; git -C "$g" config user.name t
echo "$n" > "$g/sub/file.txt"; printf '#!/bin/sh\n' > "$g/run.sh"; chmod +x "$g/run.sh"; ln -s sub/file.txt "$g/link"
git -C "$g" add -A; git -C "$g" commit -qm "$n"
C="$(git -C "$g" rev-parse HEAD)"
git -C "$g" archive --format=tar --prefix="$n-$C/" HEAD | gzip -n > "$T/tarballs/$n-$C.tar.gz"
Z=0000000000000000000000000000000000000000000000000000000000000000
V="$R/components/jdk/version"
printf 'REPO=https://github.com/openjdk/jdk25u\nREF=jdk-25.0.0+0\nDIGEST=%s\nTARBALL_SHA256=%s\n' "$C" "$Z" > "$V"
# platform: shipyard's --url exits 2 for a digest that is not 40 hex digits, as the real one does.
cat > "$T/shipyard/fetch_pinned_source.sh" <<F
#!/bin/sh
[ "\$1" = --url ] || exit 9
case "\$3" in *[!0-9a-f]*|'') echo "fetch_pinned_source: '\$3' is not a commit (40 hex digits)" >&2; exit 2 ;; esac
n="\${2##*/}"; n="\${n%.git}"
echo "file://$T/tarballs/\$n-\$3.tar.gz"
F
cat > "$T/shipyard/clone_pinned.sh" <<F
#!/bin/sh
n="\${1##*/}"; n="\${n%.git}"
git clone -q "$T/up/\$n" "\$4" && [ "\$(git -C "\$4" rev-parse HEAD)" = "\$3" ]
F
cp "$T/shipyard/clone_pinned.sh" "$T/clone_pinned.sh"
pins() { TMPDIR="$T/tmp" SHIPYARD_SCRIPTS="$T/shipyard" sh "$R/scripts/pin-source-tarballs.sh" "$@"; }
run() { rc=0; pins "$@" > "$T/out" 2>&1 || rc=$?; }
want() { [ "$rc" = "$1" ] || fail "$2: exit $rc, not $1: $(cat "$T/out")"; }
sum() { shasum -a 256 < "$T/tarballs/$n-$C.tar.gz" | cut -c1-64; }
left() { ls -A "$T/tmp"; ls -A "$R" | grep -vx -e scripts -e build -e components || true; ls -A "$R/components/jdk" | grep -vx version || true; }
tarball() {
  rm -rf "$T/fake"; mkdir -p "$T/fake"
  git -C "$g" archive --format=tar --prefix="$n-$C/" HEAD | tar xf - -C "$T/fake"
  ( cd "$T/fake/$n-$C" && eval "$1" )
  ( cd "$T/fake" && tar cf - "$n-$C" | gzip -n > "$T/tarballs/$n-$C.tar.gz" )
}

echo "-- usage: exit 2, nothing written"
cp "$V" "$T/before"
for a in --bogus "--check --check" "--check extra" -- -; do
  # shellcheck disable=SC2086  # the words are the arguments
  run $a; want 2 "usage [$a]"
  grep -q "^usage: " "$T/out" || fail "usage [$a] printed: $(cat "$T/out")"
done
cmp -s "$T/before" "$V" || fail "a usage error wrote the pin file"

echo "-- writes the tarball's SHA-256, and nothing else: exit 0; again, unchanged: exit 0"
run; want 0 "a first run"
grep -qx "TARBALL_SHA256=$(sum)" "$V" || fail "TARBALL_SHA256: $(grep TARBALL "$V")"
[ "$(diff "$T/before" "$V" | grep -c '^[<>]')" = 2 ] || fail "changed more than the one pin: $(diff "$T/before" "$V")"
cp "$V" "$T/after"; touch -t 200001010000 "$V"; touch -t 200101010000 "$T/ref"
run; want 0 "a second run"
cmp -s "$T/after" "$V" && [ -z "$(find "$V" -newer "$T/ref")" ] || fail "a second run, the pin current, rewrote the pin file"

echo "-- --check: exit 0 on a current pin; exit 3 naming a stale one, writing nothing"
run --check; want 0 "--check on a current pin"
sed "s/^TARBALL_SHA256=.*/TARBALL_SHA256=$Z/" "$V" > "$T/stale"
cp "$T/stale" "$V"
run --check; want 3 "--check on a stale TARBALL_SHA256"
grep -q "TARBALL_SHA256 is 0000" "$T/out" || fail "did not name the stale pin: $(cat "$T/out")"
cmp -s "$T/stale" "$V" || fail "--check wrote the pin file"

echo "-- a tarball that is not its commit's tree is refused: exit 1, nothing written, nothing left"
missed=""
while IFS= read -r m; do
  tarball "$m"
  for mode in "" --check; do
    # shellcheck disable=SC2086  # "" is no argument
    run $mode
    if [ "$rc" != 1 ] || ! grep -q "is not commit $C's tree" "$T/out"; then missed="$missed
  [$m] ${mode:-write}: exit $rc: $(tail -1 "$T/out")"; fi
    cmp -s "$T/stale" "$V" || { missed="$missed
  [$m] ${mode:-write}: wrote the pin file"; cp "$T/stale" "$V"; }
    [ -z "$(left)" ] || fail "[$m] $mode: left $(left)"
  done
done <<'M'
echo "not jdk" > sub/file.txt
mkdir -p .git/hooks && echo x > .git/hooks/x
mkdir sub/.git && echo x > sub/.git/config
echo "gitdir: /elsewhere" > sub/.git
mkdir empty
mv run.sh RUN.sh
M
[ -z "$missed" ] || fail "tarballs not their commit's tree, not refused:$missed"
tarball true

echo "-- an unfetchable tarball: exit 1, nothing written, nothing left"
mv "$T/tarballs/$n-$C.tar.gz" "$T/gone.tar.gz"
run; want 1 "the tarball unfetchable"
grep -q "could not fetch .*$n-$C" "$T/out" || fail "the fetch: $(cat "$T/out")"
cmp -s "$T/stale" "$V" || fail "wrote the pin file although the fetch failed"
[ -z "$(left)" ] || fail "a failed run left $(left)"
mv "$T/gone.tar.gz" "$T/tarballs/$n-$C.tar.gz"

echo "-- every other failure is exit 1 too, never a command's own 2 or 128: nothing written, nothing left"
sed 's/^DIGEST=.*/DIGEST=nope/' "$T/stale" > "$T/bad"; cp "$T/bad" "$V"
run; want 1 "a malformed DIGEST"
grep -q "'nope' is not a commit" "$T/out" || fail "a malformed DIGEST: $(cat "$T/out")"
cmp -s "$T/bad" "$V" || fail "a malformed DIGEST: wrote the pin file"
grep -v '^TARBALL_SHA256=' "$T/stale" > "$T/bad"; cp "$T/bad" "$V"
for mode in "" --check; do
  # shellcheck disable=SC2086  # "" is no argument
  run $mode; want 1 "no TARBALL_SHA256 line ${mode:-write}"
  cmp -s "$T/bad" "$V" || fail "no TARBALL_SHA256 line: wrote the pin file"
done
cp "$T/stale" "$V"
printf '#!/bin/sh\nmkdir -p "$4"\n' > "$T/shipyard/clone_pinned.sh"
run; want 1 "git status with no repository (git exits 128; a command's own status must not reach the bot as usage 2 or stale 3)"
cmp -s "$T/stale" "$V" || fail "a git failure: wrote the pin file"
[ -z "$(left)" ] || fail "a git failure left $(left)"
# platform: a fatal shell error (an unset name under set -u) exits 2 in dash and, by the time an EXIT trap reads it, 0 in macOS's bash 3.2 sh
{ cat "$T/stale"; echo 'X="${NOT_SET_ANYWHERE}"'; } > "$T/bad"; cp "$T/bad" "$V"
for mode in "" --check; do
  # shellcheck disable=SC2086  # "" is no argument
  run $mode; want 1 "an unset name in the pin file ${mode:-write} (bash 3.2 would read it as current, 0, unless the EXIT trap maps it to 1)"
  cmp -s "$T/bad" "$V" || fail "an unset name in the pin file: wrote the pin file"
done
cp "$T/stale" "$V"

echo "-- a TERM ends it at once: exit 143, nothing written, no temp file left"
{ printf '#!/bin/sh\nkill -TERM $PPID; sleep 1; exit 1\n'; } > "$T/shipyard/clone_pinned.sh"
run; want 143 "a TERM"
cmp -s "$T/stale" "$V" || fail "a TERM: wrote the pin file: $(diff "$T/stale" "$V")"
[ -z "$(left)" ] || fail "a TERM left $(left)"
echo "PASS"
