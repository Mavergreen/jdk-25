#!/bin/sh
# platform: host-agnostic
# usage: sh tests/host-cpu-test.sh
#   tests/lib/host-cpu.sh decides by the host's CPU, never by executing: host_runs_x86_64 is true only on a
#   Darwin host with no arm64 hardware (hw.optional.arm64 absent or 0) whose process is not translated
#   (sysctl.proc_translated absent or 0) and whose uname -m is x86_64 -- Mac OS X 10.9, where both sysctls
#   are absent, among them; an arm64 Mac, Rosetta or not, and a shell Rosetta translates (which reports
#   x86_64) are not. runs_natively FILE is true for a Mach-O whose architecture this host runs without
#   translation, read with file(1). Stubs on PATH play each host.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
t="$(mktemp -d "${TMPDIR:-/tmp}/host-cpu.XXXXXX")"
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $*"; exit 1; }
mkdir -p "$t/bin"
host() {  # host <uname -s> <uname -m> <hw.optional.arm64 or -> <sysctl.proc_translated or ->: stubs for that host
  printf '#!/bin/sh\ncase "$1" in -s) echo %s ;; -m) echo %s ;; *) exit 1 ;; esac\n' "$1" "$2" > "$t/bin/uname"
  {
    printf '#!/bin/sh\n[ "$1" = -n ] || exit 1\ncase "$2" in\n'
    [ "$3" = - ] || printf '  hw.optional.arm64) echo %s ;;\n' "$3"
    [ "$4" = - ] || printf '  sysctl.proc_translated) echo %s ;;\n' "$4"
    printf '  *) echo "sysctl: unknown oid '"'"'$2'"'"'" >&2; exit 1 ;;\nesac\n'
  } > "$t/bin/sysctl"
  chmod +x "$t/bin/uname" "$t/bin/sysctl"
}
x86() { ( PATH="$t/bin:$PATH"; . "$here/lib/host-cpu.sh"; host_runs_x86_64 ); }
for c in "Darwin x86_64 - -:yes:Mac OS X 10.9 (neither sysctl exists)" \
         "Darwin x86_64 0 0:yes:an Intel Mac on a newer macOS" \
         "Darwin arm64 1 0:no:an arm64 Mac" \
         "Darwin x86_64 1 1:no:a shell Rosetta translates on an arm64 Mac" \
         "Darwin x86_64 1 -:no:an arm64 Mac whose kernel lacks proc_translated" \
         "Darwin x86_64 - 1:no:a translated process with no arm64 sysctl" \
         "Linux x86_64 - -:no:Linux"; do
  h="${c%%:*}"; rest="${c#*:}"; want="${rest%%:*}"; what="${rest#*:}"
  # shellcheck disable=SC2086
  host $h
  if x86; then got=yes; else got=no; fi
  [ "$got" = "$want" ] || fail "host_runs_x86_64 on $what ($h): $got, not $want"
done

printf '\317\372\355\376\007\000\000\001\003\000\000\000\002\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' > "$t/x86_64"
printf '\317\372\355\376\014\000\000\001\000\000\000\000\002\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' > "$t/arm64"
printf '#!/bin/sh\n' > "$t/script"
nat() { ( PATH="$t/bin:$PATH"; . "$here/lib/host-cpu.sh"; runs_natively "$1" ); }
for c in "Darwin x86_64 - -:x86_64:yes" "Darwin x86_64 - -:arm64:no" \
         "Darwin arm64 1 0:arm64:yes" "Darwin arm64 1 0:x86_64:no" \
         "Darwin x86_64 1 1:x86_64:no" "Darwin x86_64 1 1:arm64:yes" \
         "Darwin arm64 1 0:script:no" "Darwin arm64 1 0:missing:no"; do
  h="${c%%:*}"; rest="${c#*:}"; f="${rest%%:*}"; want="${rest#*:}"
  # shellcheck disable=SC2086
  host $h
  if nat "$t/$f"; then got=yes; else got=no; fi
  [ "$got" = "$want" ] || fail "runs_natively $f on ($h): $got, not $want"
done

# platform: file(1) without -L describes a symlink, not its target (10.9: "symbolic link to ..."), and a
#           script launcher is no Mach-O at all, so jdk_runs_natively reads release's OS_ARCH first
jdk() {  # jdk DIR <java: x86_64|arm64|script|link-x86_64|link-arm64> <OS_ARCH or ->
  rm -rf "$1"; mkdir -p "$1/bin" "$1/real"
  case "$2" in
    script) printf '#!/bin/sh\n' > "$1/bin/java" ;;
    link-*) cp "$t/${2#link-}" "$1/real/java"; ln -s ../real/java "$1/bin/java" ;;
    *) cp "$t/$2" "$1/bin/java" ;;
  esac
  [ "$3" = - ] || printf 'JAVA_VERSION="25"\nOS_ARCH="%s"\n' "$3" > "$1/release"
}
jnat() { ( PATH="$t/bin:$PATH"; . "$here/lib/host-cpu.sh"; jdk_runs_natively "$1" ); }
for c in "Darwin arm64 1 0:link-x86_64:-:no" "Darwin arm64 1 0:script:x86_64:no" "Darwin arm64 1 0:script:amd64:no" \
         "Darwin arm64 1 0:arm64:x86_64:no" "Darwin arm64 1 0:link-arm64:-:yes" "Darwin arm64 1 0:script:aarch64:yes" \
         "Darwin arm64 1 0:script:-:yes" "Darwin x86_64 1 1:script:x86_64:no" "Darwin x86_64 - -:link-x86_64:x86_64:yes" \
         "Darwin x86_64 - -:script:aarch64:no" "Darwin arm64 1 0:x86_64:-:no" "Darwin arm64 1 0:script:sparcv9:no" \
         "Darwin arm64 1 0:x86_64:aarch64:no" "Darwin arm64 1 0:link-x86_64:arm64:no" "Darwin arm64 1 0:link-arm64:aarch64:yes" \
         "Darwin x86_64 - -:arm64:x86_64:no" "Darwin x86_64 - -:x86_64:amd64:yes"; do
  h="${c%%:*}"; rest="${c#*:}"; j="${rest%%:*}"; rest="${rest#*:}"; a="${rest%%:*}"; want="${rest#*:}"
  # shellcheck disable=SC2086
  host $h
  jdk "$t/jdk" "$j" "$a"
  if jnat "$t/jdk"; then got=yes; else got=no; fi
  [ "$got" = "$want" ] || fail "jdk_runs_natively, java $j, OS_ARCH $a, on ($h): $got, not $want"
done
echo "PASS: host-cpu"
