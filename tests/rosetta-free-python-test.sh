#!/bin/sh
# platform: host-agnostic -- needs python3 with a user site and no PyYAML of its own; exits 77 otherwise
# usage: sh tests/rosetta-free-python-test.sh
#   tests/rosetta-free-test.sh's workflow half must run with the python3 its PyYAML probe found, with the
#   same flags: shipyard's install action puts PyYAML in the user site (pip --user), where a probe without
#   -I finds it and a run with -I (which implies -s) does not. With a stub yaml importable only from a
#   scratch HOME's user site, the guard must use it: PASS, the stub's marker written, no ModuleNotFoundError
#   and no skipped workflow half.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$here/.." && pwd)"
fail() { echo "FAIL $*"; exit 1; }
command -v python3 > /dev/null 2>&1 || { echo "SKIP rosetta-free-python: no python3"; exit 77; }
command -v git > /dev/null 2>&1 || { echo "SKIP rosetta-free-python: no git"; exit 77; }
t="$(mktemp -d "${TMPDIR:-/tmp}/rosetta-free-python.XXXXXX")"
trap 'rm -rf "$t"' EXIT
h="$t/home"; mkdir -p "$h"
# platform: git refuses a repository another uid owns unless the global config names it safe, and
#           this HOME has none; the guard runs git ls-files in it
printf '[safe]\n\tdirectory = %s\n' "$REPO" > "$h/.gitconfig"
if HOME="$h" python3 -E -c 'import yaml' > /dev/null 2>&1; then
  echo "SKIP rosetta-free-python: this python3 has PyYAML outside a user site, so the user-site case cannot be built"; exit 77
fi
site="$(HOME="$h" python3 -E -c 'import site, sys; print(site.getusersitepackages() if site.ENABLE_USER_SITE else "")')"
[ -n "$site" ] || { echo "SKIP rosetta-free-python: this python3 has no user site"; exit 77; }
case "$site" in "$h"/*) ;; *) echo "SKIP rosetta-free-python: this python3's user site, $site, is not under HOME"; exit 77 ;; esac
mkdir -p "$site"
cat > "$site/yaml.py" <<'PY'
import os
def safe_load(stream):
    with open(os.path.join(os.environ["HOME"], "yaml-used"), "a") as f:
        f.write("used\n")
    return {}
PY
rc=0; HOME="$h" sh "$here/rosetta-free-test.sh" "$REPO" > "$t/out" 2>&1 || rc=$?
grep -q ModuleNotFoundError "$t/out" && fail "the guard's workflow half could not import the user site's yaml: $(cat "$t/out")"
grep -q 'SKIP the workflow half' "$t/out" && fail "the guard skipped its workflow half though the probe can import yaml: $(cat "$t/out")"
[ "$rc" = 0 ] || fail "the guard exited $rc with PyYAML in the user site: $(cat "$t/out")"
[ -s "$h/yaml-used" ] || fail "the guard passed without the user site's yaml: $(cat "$t/out")"
echo "PASS: rosetta-free-python (the workflow half ran on PyYAML from the user site)"
