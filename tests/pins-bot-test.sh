#!/bin/sh
# platform: host-agnostic
# usage: sh tests/pins-bot-test.sh
#   .github/workflows/pins-bot.yml fills a JDK bump's pins on Renovate's branch: Renovate moves GA alone,
#   and the bot writes the REF, DIGEST and TARBALL_SHA256 that follow from it. Its decisions are
#   scripts/pins-bot.sh's: `moved` must say yes exactly when a source pin line (GA, REF, DIGEST,
#   TARBALL_SHA256) moved since the branch left main (a JDK bump), and no for any other change; `values`
#   must hand on the three filled pins and refuse one of the wrong shape; `apply` must write those lines
#   and nothing else, report whether it changed anything, and refuse another key, a bad value or a key
#   given twice before writing. `fill` is the pins job's whole decision, by the exit codes of
#   scripts/resolve-ga.sh (REF and DIGEST) and then scripts/pin-source-tarballs.sh (TARBALL_SHA256):
#   nothing when no source pin moved or both --check say 0 (current); each write whose --check says 3
#   (stale), then the values; a failure, with no write and no value, for any other --check status (1, an
#   error: never mistaken for stale) or a failed write. `moved` must exit 2, never 1, when git cannot
#   tell (a failed diff), so `fill` fails rather than do nothing.
#   The workflow must give the job that reads upstream's tarball no write token, and the job that holds
#   one no upstream bytes; run on a push to renovate/** and nothing else; put no ${{ }} in a run: block;
#   persist no credentials in the pins job's checkout; and run the push job only after the pins job. Each
#   of those last four checks is run against a workflow mutated to break it, and must refuse it. The push
#   job writes with the pins-bot App's token alone (contents: write; its GITHUB_TOKEN reads), dispatches
#   nothing, and commits as the App's bot, whom renovate.json's gitIgnoredAuthors names.
#   Offline: a fixture repository with this repo's pin file stands in for the Renovate branch, and stubs
#   stand in for resolve-ga.sh and pin-source-tarballs.sh.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
git --version >/dev/null 2>&1 || { echo "no git that runs -- skipping"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pins-bot.XXXXXX")"
trap 'rm -rf "$T"' EXIT
R="$T/repo"; mkdir -p "$R/scripts" "$R/components/jdk"
V="$R/components/jdk/version"
cp "$REPO/scripts/pins-bot.sh" "$R/scripts/"; cp "$REPO/components/jdk/version" "$V"
echo OTHER=1 >> "$V"   # a line that is no source pin
git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
git -C "$R" add -A; git -C "$R" commit -qm main; git -C "$R" branch -m main
bot() { ( cd "$R" && sh scripts/pins-bot.sh "$@" ); }
Z=0000000000000000000000000000000000000000000000000000000000000000
edit() { sed "s|^$1=.*|$1=$2|" "$V" > "$T/p" && cat "$T/p" > "$V"; }
pin() { sed -n 's/^TARBALL_SHA256=//p' "$REPO/components/jdk/version"; }

echo "-- moved: a non-pin line is not a source pin; a REF bump is, even after main moved on"
git -C "$R" checkout -q -b renovate/other; edit OTHER 2; git -C "$R" commit -qam other
if bot moved main > "$T/out"; then fail "a change to no source pin counted as a moved source pin: $(cat "$T/out")"; fi
git -C "$R" checkout -q main; edit TARBALL_SHA256 "$Z"; git -C "$R" commit -qam later
git -C "$R" checkout -q -b renovate/jdk HEAD~1; edit REF jdk-25.0.5+1; git -C "$R" commit -qam jdk
bot moved main > "$T/out" || fail "a moved REF was not seen"
[ "$(grep -c '^[-+]REF=' "$T/out")" = 2 ] && [ "$(wc -l < "$T/out" | tr -d ' ')" = 2 ] || fail "moved printed: $(cat "$T/out")"
for k in GA DIGEST TARBALL_SHA256; do
  git -C "$R" checkout -q -b "renovate/$k" main~1; edit $k 2222222222222222222222222222222222222222; git -C "$R" commit -qam "$k"
  bot moved main > "$T/out" || fail "a moved $k was not seen"
done
git -C "$R" checkout -q renovate/jdk
mkdir -p "$T/faildiff"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = diff ] && { echo "fatal: no diff today" >&2; exit 128; }; done\nexec "%s" "$@"\n' \
  "$(command -v git)" > "$T/faildiff/git"; chmod +x "$T/faildiff/git"
# platform: in a subshell, as macOS's /bin/sh (bash 3.2) keeps a PATH=... prefix on a function call after it.
rc=0; (PATH="$T/faildiff:$PATH"; bot moved main) > "$T/out" 2> "$T/err" || rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$T/out" ] || fail "moved, a failed git diff: exit $rc, not 2 (never 1, which reads as no source pin moved), printed [$(cat "$T/out")]"
grep -q 'pins-bot: git diff .* failed' "$T/err" || fail "moved, a failed git diff: said [$(cat "$T/err")]"

echo "-- values: the three filled pins on one line; a bad one refused"
want="REF=$(sed -n 's/^REF=//p' "$V") DIGEST=$(sed -n 's/^DIGEST=//p' "$V") TARBALL_SHA256=$(pin)"
[ "$(bot values)" = "$want" ] || fail "values: $(bot values), not $want"
for b in "TARBALL_SHA256 abc" "DIGEST abc" "REF jdk-25.0.6" "REF jdk-25.0.5+8;x"; do
  edit ${b% *} "${b#* }"
  if bot values > /dev/null 2> "$T/err"; then fail "handed on ${b% *}=${b#* }"; fi
  grep -q "${b% *} is '" "$T/err" || fail "values: $(cat "$T/err")"
  git -C "$R" checkout -q -- components/jdk/version
done

echo "-- apply: the one line, nothing else; unchanged when it holds the value; refusals write nothing"
cp "$V" "$T/before"
[ "$(bot apply TARBALL_SHA256=$Z)" = changed ] || fail "apply did not say changed"
[ "$(diff "$T/before" "$V" | grep -c '^>')" = 1 ] || fail "apply changed: $(diff "$T/before" "$V")"
grep -qx "TARBALL_SHA256=$Z" "$V" || fail "TARBALL_SHA256 not written"
[ "$(bot apply TARBALL_SHA256=$Z)" = unchanged ] || fail "a second apply of the same value changed the pin file"
cp "$V" "$T/now"
for bad in "DIGEST=$Z" "TARBALL_SHA256=${Z%0}" "TARBALL_SHA256=$Z TARBALL_SHA256=$Z" "TARBALL_SHA256=\$(touch $T/pwned)" \
  "GA=jdk-25.0.6-ga" "REF=jdk-25.0.5+8\$(touch $T/pwned)" "REF=jdk-25.0.6" "DIGEST=${Z%????????????????????????}x" \
  "REF=jdk-25.0.5+8 DIGEST=${Z%????????????????????????} TARBALL_SHA256=$Z OTHER=1"; do
  # shellcheck disable=SC2086
  if bot apply $bad > /dev/null 2>&1; then fail "applied [$bad]"; fi
  cmp -s "$T/now" "$V" || fail "a refused [$bad] wrote the pin file"
done
[ ! -e "$T/pwned" ] || fail "apply ran a value"
D40=4444444444444444444444444444444444444444
[ "$(bot apply REF=jdk-25.0.9+9 DIGEST=$D40 TARBALL_SHA256=$Z)" = changed ] || fail "apply of all three did not say changed"
grep -qx 'REF=jdk-25.0.9+9' "$V" && grep -qx "DIGEST=$D40" "$V" && grep -qx "TARBALL_SHA256=$Z" "$V" \
  && [ "$(diff "$T/before" "$V" | grep -c '^>')" = 3 ] || fail "apply of all three wrote: $(diff "$T/before" "$V")"

echo "-- fill: --check 0 nothing to do; 3 the write, then the value; anything else fails, writing nothing"
git -C "$R" checkout -q -- components/jdk/version
E=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
cat > "$R/scripts/resolve-ga.sh" <<'STUB'
#!/bin/sh
echo "${1:-write}" >> "$STUB_GA_LOG"
case "${1:-}" in --check) exit "$STUB_GA_CHECK" ;; esac
[ "$STUB_GA_WRITE" = 0 ] || exit "$STUB_GA_WRITE"
p="$(dirname "$0")/../components/jdk/version"
sed -e "s|^REF=.*|REF=jdk-25.0.9+9|" -e "s|^DIGEST=.*|DIGEST=9999999999999999999999999999999999999999|" "$p" > "$p.new" && mv "$p.new" "$p"
STUB
cat > "$R/scripts/pin-source-tarballs.sh" <<'STUB'
#!/bin/sh
echo "${1:-write}" >> "$STUB_LOG"
case "${1:-}" in --check) exit "$STUB_CHECK" ;; esac
[ "$STUB_WRITE" = 0 ] || exit "$STUB_WRITE"
p="$(dirname "$0")/../components/jdk/version"
sed "s|^TARBALL_SHA256=.*|TARBALL_SHA256=$STUB_SHA|" "$p" > "$p.new" && mv "$p.new" "$p"
STUB
fill() {  # fill <base-ref> <--check status> <write status> [<GA --check> <GA write>]: pins-bot.sh fill's status; $T/out, $T/calls, $T/gacalls
  : > "$T/calls"; : > "$T/gacalls"
  ( cd "$R" && env STUB_LOG="$T/calls" STUB_CHECK="$2" STUB_WRITE="$3" STUB_SHA="$E" \
      STUB_GA_LOG="$T/gacalls" STUB_GA_CHECK="${4:-0}" STUB_GA_WRITE="${5:-0}" sh scripts/pins-bot.sh fill "$1" ) > "$T/out" 2> "$T/err"
}
gacalls() { tr '\n' ' ' < "$T/gacalls" | sed 's/ $//'; }
calls() { tr '\n' ' ' < "$T/calls" | sed 's/ $//'; }
cp "$V" "$T/now"
fill main 0 0 || fail "fill, --check current: exit $? ($(cat "$T/err"))"
[ ! -s "$T/out" ] && [ "$(calls)" = --check ] || fail "fill, --check current: handed on [$(cat "$T/out")], calls [$(calls)]"
cmp -s "$T/now" "$V" || fail "fill, --check current: the pin file changed"
fill main 3 0 || fail "fill, --check stale: exit $? ($(cat "$T/err"))"
[ "$(calls)" = "--check write" ] || fail "fill, --check stale: calls [$(calls)]"
want="REF=$(sed -n 's/^REF=//p' "$T/now") DIGEST=$(sed -n 's/^DIGEST=//p' "$T/now") TARBALL_SHA256=$E"
[ "$(cat "$T/out")" = "$want" ] || fail "fill, --check stale: handed on [$(cat "$T/out")], not [$want]"
cp "$T/now" "$V"
fill main 3 0 3 0 || fail "fill, GA and tarball stale: exit $? ($(cat "$T/err"))"
[ "$(gacalls)" = "--check write" ] && [ "$(calls)" = "--check write" ] || fail "fill, GA and tarball stale: GA calls [$(gacalls)], tarball calls [$(calls)]"
[ "$(cat "$T/out")" = "REF=jdk-25.0.9+9 DIGEST=9999999999999999999999999999999999999999 TARBALL_SHA256=$E" ] \
  || fail "fill, GA and tarball stale: handed on [$(cat "$T/out")]"
cp "$T/now" "$V"
for rc in 1 2 7; do
  if fill main 3 0 "$rc" 0; then fail "fill, resolve-ga --check exit $rc: exit 0, handed on [$(cat "$T/out")]"; fi
  [ ! -s "$T/out" ] && [ "$(gacalls)" = --check ] && [ ! -s "$T/calls" ] || fail "fill, resolve-ga --check exit $rc: handed on [$(cat "$T/out")], GA calls [$(gacalls)], tarball calls [$(calls)]"
  cmp -s "$T/now" "$V" || fail "fill, resolve-ga --check exit $rc: the pin file changed"
done
if fill main 3 0 3 1; then fail "fill, a failed GA write: exit 0"; fi
[ ! -s "$T/out" ] && [ ! -s "$T/calls" ] || fail "fill, a failed GA write: handed on [$(cat "$T/out")], tarball calls [$(calls)]"
cp "$T/now" "$V"
for rc in 1 2 130 143 7; do
  if fill main "$rc" 0; then fail "fill, --check exit $rc: exit 0, handed on [$(cat "$T/out")]"; fi
  [ ! -s "$T/out" ] && [ "$(calls)" = --check ] || fail "fill, --check exit $rc: handed on [$(cat "$T/out")], calls [$(calls)]"
  cmp -s "$T/now" "$V" || fail "fill, --check exit $rc: the pin file changed"
done
grep -q 'pin-source-tarballs.sh --check exited 7' "$T/err" || fail "fill, --check exit 7: said [$(cat "$T/err")]"
if fill main 3 1; then fail "fill, a failed write: exit 0"; fi
[ ! -s "$T/out" ] && [ "$(calls)" = "--check write" ] || fail "fill, a failed write: handed on [$(cat "$T/out")], calls [$(calls)]"
if fill nosuchref 3 0; then fail "fill, no merge base: exit 0"; fi
[ ! -s "$T/out" ] && [ ! -s "$T/calls" ] && [ ! -s "$T/gacalls" ] || fail "fill, no merge base: handed on [$(cat "$T/out")], calls [$(calls)]"
if (PATH="$T/faildiff:$PATH"; fill main 3 0); then fail "fill, a failed git diff: exit 0 (read as no source pin moved)"; fi
[ ! -s "$T/out" ] && [ ! -s "$T/calls" ] || fail "fill, a failed git diff: handed on [$(cat "$T/out")], calls [$(calls)]"
grep -q 'could not tell whether a source pin moved (moved exited 2)' "$T/err" || fail "fill, a failed git diff: said [$(cat "$T/err")]"
git -C "$R" checkout -q renovate/other
fill main 3 0 || fail "fill, a non-pin change: exit $? ($(cat "$T/err"))"
[ ! -s "$T/out" ] && [ ! -s "$T/calls" ] || fail "fill, a non-pin change: handed on [$(cat "$T/out")], calls [$(calls)]"

echo "-- the workflow: Renovate's branches only; the job that reads upstream has no write token, the one with it no upstream"
W="$REPO/.github/workflows/pins-bot.yml"
grep -qx "    branches: \['renovate/\*\*'\]" "$W" || fail "pins-bot.yml does not run on renovate/** pushes alone"
grep -qx 'permissions: {}' "$W" || fail "pins-bot.yml grants a default permission"
awk '/^  pins:$/ { j = "pins" } /^  push:$/ { j = "push" } j { print j ": " $0 }' "$W" > "$T/jobs"
grep -qx 'pins:       contents: read' "$T/jobs" || fail "the pins job's permissions: $(grep '^pins:' "$T/jobs" | grep -A2 permissions)"
if grep '^pins:' "$T/jobs" | grep -q 'write\|git push\|gh workflow'; then fail "the pins job can write"; fi
if grep '^push:' "$T/jobs" | grep -q 'pin-source-tarballs\|curl\|install@'; then fail "the push job touches upstream's tarballs"; fi
[ "$(grep -A1 '^push:     permissions:$' "$T/jobs" | tail -1)" = 'push:       contents: read' ] \
  && ! grep '^push:' "$T/jobs" | grep -q 'contents: write$\|actions: write' || fail "the push job's GITHUB_TOKEN permissions (it reads only; the App's token writes, so the push itself starts release.yml: no dispatch)"
grep -qx 'push:         uses: actions/create-github-app-token@v3' "$T/jobs" \
  && grep -qx 'push:           client-id: ${{ vars.PINS_BOT_CLIENT_ID }}' "$T/jobs" \
  && grep -qx 'push:           private-key: ${{ secrets.PINS_BOT_PRIVATE_KEY }}' "$T/jobs" \
  && [ "$(grep -c '^push: *permission-' "$T/jobs")" = 1 ] && grep -qx 'push:           permission-contents: write' "$T/jobs" \
  || fail "the push job does not mint the pins-bot App's token for contents: write alone"
grep -qx 'push:           token: ${{ steps.app.outputs.token }}' "$T/jobs" || fail "the push job's checkout does not hold the App's token"
if grep '^push:' "$T/jobs" | grep -q 'persist-credentials: false'; then fail "the push job's checkout persists no credentials: its git push authenticates with them, so persisting none would break the push, not harden it"; fi
grep -qxF "  group: pins-bot-\${{ github.ref }}\${{ github.actor == 'mavergreen-pins-bot[bot]' && format('-{0}', github.run_id) || '' }}" "$W" \
  && grep -qxF "pins:     if: github.actor != 'mavergreen-pins-bot[bot]'" "$T/jobs" \
  || fail "the run the bot's own push starts can cancel the run that pushed (which would show as cancelled), or checks again"
if grep -q 'gh workflow run\|GH_TOKEN\|github.token' "$W"; then fail "the workflow dispatches a run or uses GITHUB_TOKEN to write: a push made with GITHUB_TOKEN starts no workflow, and a run it dispatches does not count for the PR's required check; the App's push starts release.yml, whose build is the required check on the new head"; fi
grep -qF "user.email='342268518+mavergreen-pins-bot[bot]@users.noreply.github.com'" "$W" \
  && grep -qF '"342268518+mavergreen-pins-bot[bot]@users.noreply.github.com"' "$REPO/.github/renovate.json" \
  || fail "the bot's commit email is not the App's, or renovate.json's gitIgnoredAuthors lacks it"
grep -qx 'pins:           pins="$(sh scripts/pins-bot.sh fill origin/main)"' "$T/jobs" || fail "the pins job does not decide by pins-bot.sh fill"
grep -qx 'push:           applied="$(sh scripts/pins-bot.sh apply $PINS)"' "$T/jobs" || fail "the push job does not fail on a refused apply (its status is taken by an assignment, where set -e sees it)"
if grep '^push:' "$T/jobs" | grep -qF '[ "$(sh scripts/pins-bot.sh apply'; then fail "the push job reads a refused apply as unchanged (a [ \"\$(...)\" = changed ] test swallows its status)"; fi
if grep '^pins:' "$T/jobs" | grep -v '^pins: *#' | grep -q 'pin-source-tarballs'; then fail "the pins job runs pin-source-tarballs.sh around pins-bot.sh fill"; fi

echo "-- the workflow's security invariants, each shown to catch its own breakage"
# spec: .github/workflows/pins-bot.yml and INGREDIENTS.md -- this repo's own design; invariants <workflow> prints the first one it breaks, and fails
#       on: is a push to renovate/** and nothing else (no pull_request_target, no workflow_dispatch, no other branch);
#       no run: block holds ${{ }} (a value an attacker can shape reaches a shell only through env:);
#       the pins job's checkout persists no credentials (its token never sits in .git/config beside upstream's bytes);
#       the push job needs the pins job (it runs only on values the pins job checked).
invariants() {
  _on="$(awk '/^on:/ { on = 1; next } on && /^[^ #]/ { exit } on && !/^ *(#.*)?$/ { print }' "$1")"
  [ "$_on" = "  push:
    branches: ['renovate/**']" ] || { echo "on: is not a push to renovate/** alone: [$_on]"; return 1; }
  _run="$(awk 'function ind(l) { match(l, /^ */); return RLENGTH }
    r && (/^ *$/ || ind($0) > ri) { if (index($0, "${{")) print NR ": " $0; next }
    { r = 0 }
    /^ *(- )?run:/ { ri = ind($0); r = 1; if (index($0, "${{")) print NR ": " $0 }' "$1")"
  [ -z "$_run" ] || { echo "a run: block holds \${{ }} (a value an attacker can shape reaches a shell only through env:): $_run"; return 1; }
  awk '/^  pins:$/ { j = "pins" } /^  push:$/ { j = "push" } j { print j ": " $0 }' "$1" > "$T/inv-jobs"
  grep -q '^pins:           persist-credentials: false\( *#.*\)\{0,1\}$' "$T/inv-jobs" \
    || { echo "the pins job's checkout persists its credentials"; return 1; }
  grep -qx 'push:     needs: pins' "$T/inv-jobs" || { echo "the push job does not need the pins job"; return 1; }
}
invariants "$W" > "$T/inv" || fail "pins-bot.yml: $(cat "$T/inv")"
mutant() {  # mutant <what it breaks> <expected message> <sed script> -- invariants must refuse the mutated workflow
  sed "$3" "$W" > "$T/mutant.yml"
  if cmp -s "$W" "$T/mutant.yml"; then fail "mutant '$1' changed nothing"; fi
  if invariants "$T/mutant.yml" > "$T/inv"; then fail "invariants passed a workflow with $1"; fi
  grep -qF "$2" "$T/inv" || fail "invariants, $1: said [$(cat "$T/inv")]"
}
mutant "a pull_request_target trigger" "on: is not a push" 's/^  push:$/  pull_request_target:\
  push:/'
mutant "a workflow_dispatch trigger" "on: is not a push" 's/^permissions: {}$/  workflow_dispatch:\
permissions: {}/'
mutant "another branch" "on: is not a push" "s|'renovate/\*\*'|'**'|"
mutant "\${{ }} in a one-line run:" 'a run: block holds' 's/^      - name: Install mavericks-shipyard$/      - run: echo ${{ github.head_ref }}\
&/'
mutant "\${{ }} in a run: block" 'a run: block holds' 's/^          set -eu$/          echo "${{ github.event.head_commit.message }}"/'
mutant "the pins job keeping its credentials" "persists its credentials" 's/persist-credentials: false/persist-credentials: true/'
mutant "a push job that needs nothing" "does not need the pins job" '/^    needs: pins$/d'
echo "PASS"
