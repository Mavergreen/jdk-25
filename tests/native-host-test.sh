#!/bin/sh
# platform: macOS-only -- sources build/toolchain.sh, whose 10.9 branches it reaches with a uname that says Darwin 13
# usage: sh tests/native-host-test.sh
#   build/toolchain.sh on Mac OS X 10.9, which builds natively: jdk_target_args prints nothing there (no
#   --openjdk-target) and --openjdk-target=x86_64-apple-darwin elsewhere; jdk_boot_jdk is the installed
#   /usr/local/mavergreen/jdk25, refused, naming it, when its bin/java is missing; jdk_boot_jdk_id HOME is
#   jdk25-<its release's JAVA_RUNTIME_VERSION> there and components/bootjdk/version's TAG elsewhere; and
#   jdk_toolchain's clang22 is the installed /usr/local/mavergreen/clang22, refused, naming it, when
#   absent. On a real 10.9 with both installed, the installed ones are what it gets; elsewhere the installed
#   jdk25 is never run (PORT.md ruling R18): jdk_boot_jdk runs its java -version.
#   jdk_cxx_native_flags is "-include sys/_types.h" on 10.9 and nothing elsewhere, and C++ including
#   <iostream> compiles with clang22 against the 10.9 SDK with jdk_toolchain's CXX and those flags (on 10.9,
#   CXX alone). Off 10.9, the same compile without them must still fail: when it passes, clang22's libc++
#   is fixed and INGREDIENTS.md's native-cxx-include deviation goes.
#   jdk_build_tool_ldflags, after jdk_toolchain, is jdk_link_flags on 10.9 (PORT.md ruling R56) and nothing
#   elsewhere. CXX with those flags, as patches/0019 links a native build tool, links an x86_64
#   std::hash<std::string> and std::unordered_map user against the 10.9 SDK (never run): clean by the
#   compat guard, no libc++.1.dylib load command. CXX alone, which is what adlc linked with, must fail on
#   std::__1::__hash_memory.
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
  # spec: PORT.md ruling R18 -- jdk_boot_jdk runs the installed x86_64 java -version, so only on a real 10.9
  if onhost 'jdk_host_is_109'; then
    got="$(onhost 'jdk_boot_jdk')" || fail "jdk_boot_jdk refused the installed jdk25 on this 10.9"
    [ "$got" = /usr/local/mavergreen/jdk25 ] || fail "jdk_boot_jdk on 10.9 printed '$got'"
  fi
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
got="$(in109 'jdk_cxx_native_flags')"
[ "$got" = "-include sys/_types.h" ] || fail "jdk_cxx_native_flags on 10.9 printed '$got', not -include sys/_types.h"
cxx="$(onhost 'jdk_toolchain > /dev/null 2>&1 && printf %s "$CXX"')" || fail "jdk_toolchain failed"
printf '#include <iostream>\nint main() { std::cout << 1; return 0; }\n' > "$t/io.cc"
if onhost 'jdk_host_is_109'; then
  $cxx -std=c++14 -c -o "$t/io.o" "$t/io.cc" > "$t/o" 2>&1 || fail "jdk_toolchain's CXX on this 10.9 cannot compile <iostream>: $(head -5 "$t/o")"
else
  [ -z "$(onhost 'jdk_cxx_native_flags')" ] || fail "jdk_cxx_native_flags off 10.9 printed '$(onhost 'jdk_cxx_native_flags')': the cross build's CXX must not change"
  case "$cxx" in *sys/_types.h*) fail "the cross build's CXX includes sys/_types.h: $cxx" ;; esac
  # shellcheck disable=SC2086  # CXX is a command line
  $cxx $got -std=c++14 -c -o "$t/io.o" "$t/io.cc" > "$t/o" 2>&1 \
    || fail "clang22 cannot compile <iostream> against the 10.9 SDK even with $got: $(head -5 "$t/o")"
  # shellcheck disable=SC2086
  if $cxx -std=c++14 -c -o "$t/io.o" "$t/io.cc" > /dev/null 2>&1; then
    fail "clang22's libc++ now compiles <iostream> against the 10.9 SDK without $got: delete INGREDIENTS.md's native-cxx-include deviation and jdk_cxx_native_flags"
  fi
fi
printf '#include <functional>\n#include <string>\n#include <unordered_map>\nint main(int c, char **v) { std::unordered_map<std::string, int> m; m[v[0]] = c; return (int)(std::hash<std::string>()(v[0]) + m.size()); }\n' > "$t/hash.cc"
lk="$(/bin/sh -c '. "$MAVERICKS_ROOT/build/toolchain.sh"; jdk_toolchain > /dev/null 2>&1 || exit 9; jdk_link_flags')" \
  || fail "jdk_link_flags failed"
got="$(/bin/sh -c '. "$MAVERICKS_ROOT/build/toolchain.sh"; jdk_toolchain > /dev/null 2>&1 || exit 9
  PATH="$1:$PATH"; jdk_build_tool_ldflags' x "$t/bin")" || fail "jdk_build_tool_ldflags failed under the 10.9 uname"
[ "$got" = "$lk" ] || fail "jdk_build_tool_ldflags under the 10.9 uname printed '$got', not jdk_link_flags"
if ! onhost 'jdk_host_is_109'; then
  got="$(onhost 'jdk_build_tool_ldflags')" || fail "jdk_build_tool_ldflags failed"
  [ -z "$got" ] || fail "jdk_build_tool_ldflags off 10.9 printed '$got': the cross build's build tools must not change"
fi
# shellcheck disable=SC2086  # CXX and the link flags are command lines
$cxx $lk -std=c++14 -o "$t/hash" "$t/hash.cc" > "$t/o" 2>&1 \
  || fail "CXX with jdk_build_tool_ldflags cannot link a std::hash<std::string> user: $(head -5 "$t/o")"
/bin/sh -c '. "$MAVERICKS_ROOT/build/toolchain.sh"; jdk_compat_guard "$1"' x "$t/hash" > "$t/o" 2>&1 || fail "the build-tool link fails the compat guard: $(cat "$t/o")"
if otool -L "$t/hash" | grep -q '/libc++\.1\.dylib '; then fail "the build-tool link loads libc++.1.dylib, not clang22's libc++ (ruling R21)"; fi
if ! onhost 'jdk_host_is_109'; then
  # shellcheck disable=SC2086  # CXX is a command line
  if $cxx -include sys/_types.h -std=c++14 -o "$t/hash2" "$t/hash.cc" > "$t/o" 2>&1; then
    fail "CXX alone now links a std::hash<std::string> user against the 10.9 SDK: PORT.md ruling R56 and patches/0019 may no longer be needed"
  fi
  grep -q '__hash_memory' "$t/o" || fail "CXX alone failed to link for another reason than __hash_memory: $(head -5 "$t/o")"
fi
echo "PASS: native-host"
