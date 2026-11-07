#!/bin/sh
# platform: macOS-only -- sources build/toolchain.sh, whose 10.9 branches it reaches with a uname that says Darwin 13
# usage: sh tests/native-host-test.sh
#   build/toolchain.sh on Mac OS X 10.9, which builds natively: jdk_target_args prints nothing there (no
#   --openjdk-target) and --openjdk-target=x86_64-apple-darwin elsewhere; jdk_boot_jdk is the installed
#   /usr/local/mavergreen/jdk25, refused, naming it, when its bin/java is missing; jdk_boot_jdk_id HOME is
#   jdk25-<its release's JAVA_RUNTIME_VERSION> there and components/bootjdk/version's TAG elsewhere; and
#   jdk_toolchain's clang22 is the installed /usr/local/mavergreen/clang22, refused, naming it, when
#   absent. On a real 10.9 with both installed, the installed ones are what it gets.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$here/.." && pwd)"; export MAVERICKS_ROOT
fail() { echo "FAIL $*"; exit 1; }
[ "$(uname -s)" = Darwin ] || { echo "SKIP: build/toolchain.sh needs macOS"; exit 77; }
t="$(mktemp -d "${TMPDIR:-/tmp}/native-host-test.XXXXXX")"
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
cat > "$t/bin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in -s) echo Darwin ;; -r) echo 13.4.0 ;; -m) echo x86_64 ;; *) echo Darwin ;; esac
EOF
chmod +x "$t/bin/uname"
tag="$(sed -n 's/^TAG=//p' "$MAVERICKS_ROOT/components/bootjdk/version" | tr -d '[:space:]')"
mkdir -p "$t/home"; printf 'JAVA_RUNTIME_VERSION="25.0.5.0.3+3-mavericks.1"\nJAVA_VERSION="25.0.5.0.3"\n' > "$t/home/release"

in109() { PATH="$t/bin:$PATH" /bin/sh -c '. "$MAVERICKS_ROOT/build/toolchain.sh"; '"$1"; }
onhost() { /bin/sh -c '. "$MAVERICKS_ROOT/build/toolchain.sh"; '"$1"; }

[ "$(in109 'jdk_host_is_109 && echo yes')" = yes ] || fail "the uname stub does not make jdk_host_is_109 true"
got="$(in109 'jdk_target_args')" || fail "jdk_target_args failed on 10.9"
[ -z "$got" ] || fail "jdk_target_args on 10.9 printed '$got': a native build takes no --openjdk-target"
got="$(PATH="$t/bin:$PATH" /bin/sh -c '. "$MAVERICKS_ROOT/build/toolchain.sh"; jdk_boot_jdk_id "$1"' x "$t/home")" \
  || fail "jdk_boot_jdk_id failed on 10.9"
[ "$got" = jdk25-25.0.5.0.3+3-mavericks.1 ] || fail "jdk_boot_jdk_id on 10.9 printed '$got', not jdk25-<JAVA_RUNTIME_VERSION>"

if ! onhost 'jdk_host_is_109'; then
  got="$(onhost 'jdk_target_args')" || fail "jdk_target_args failed"
  [ "$got" = --openjdk-target=x86_64-apple-darwin ] || fail "jdk_target_args off 10.9 printed '$got'"
  got="$(/bin/sh -c '. "$MAVERICKS_ROOT/build/toolchain.sh"; jdk_boot_jdk_id "$1"' x "$t/home")" || fail "jdk_boot_jdk_id failed"
  [ "$got" = "$tag" ] || fail "jdk_boot_jdk_id off 10.9 printed '$got', not the pinned $tag"
fi

if [ -x /usr/local/mavergreen/jdk25/bin/java ]; then
  got="$(in109 'jdk_boot_jdk')" || fail "jdk_boot_jdk refused the installed jdk25 on 10.9"
  [ "$got" = /usr/local/mavergreen/jdk25 ] || fail "jdk_boot_jdk on 10.9 printed '$got'"
else
  if in109 'jdk_boot_jdk' > "$t/o" 2>&1; then fail "jdk_boot_jdk on 10.9 succeeded with no jdk25 installed: $(cat "$t/o")"; fi
  grep -q '/usr/local/mavergreen/jdk25' "$t/o" || fail "jdk_boot_jdk's refusal does not name /usr/local/mavergreen/jdk25: $(cat "$t/o")"
fi
if [ -x /usr/local/mavergreen/clang22/bin/clang ]; then
  # platform: with clang22 installed, jdk_toolchain goes on to fetch the SDK and Recaulk; only a real
  #           10.9 is checked that far.
  if onhost 'jdk_host_is_109'; then
    got="$(onhost 'jdk_toolchain >/dev/null && echo "$CLANG22"')" || fail "jdk_toolchain failed on this 10.9"
    [ "$got" = /usr/local/mavergreen/clang22 ] || fail "jdk_toolchain on 10.9 took clang22 from '$got'"
  fi
else
  if in109 'jdk_toolchain' > "$t/o" 2>&1; then fail "jdk_toolchain on 10.9 succeeded with no clang22 installed"; fi
  grep -q 'no clang22 at /usr/local/mavergreen/clang22' "$t/o" || fail "jdk_toolchain's refusal does not name /usr/local/mavergreen/clang22: $(cat "$t/o")"
fi
echo "PASS: native-host"
