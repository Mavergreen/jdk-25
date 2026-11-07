# platform: host-agnostic -- sourced, never run: uname, sysctl and file(1) only, with no shipyard, so the 10.9 guest can source it
#   usage: . tests/lib/host-cpu.sh; host_runs_x86_64; runs_natively FILE; jdk_runs_natively JDK_HOME
#          Decides by the host's CPU, never by executing what it asks about. host_runs_x86_64 is true on a
#          Darwin host that runs x86_64 natively: no arm64 hardware (hw.optional.arm64 absent or 0), not a
#          process Rosetta translates (sysctl.proc_translated absent or 0, since a translated shell's uname -m
#          says x86_64), and uname -m x86_64. Mac OS X 10.9 has neither sysctl, and is such a host.
#          runs_natively FILE is true when FILE is a Mach-O (file(1)) with a slice this host runs untranslated:
#          x86_64 only where host_runs_x86_64, arm64 only on arm64 hardware.
#          jdk_runs_natively JDK_HOME judges a whole JDK, so a symlinked bin/java or a script launcher cannot
#          slip past: the arch its release file's OS_ARCH names (x86_64/amd64, aarch64/arm64; any other
#          is never native), and a Mach-O bin/java, read through symlinks (file -bL), must carry that arch
#          too; with no release, bin/java's own arch; true for neither, as for a test's stand-in JDK of
#          shell scripts.
# spec: PORT.md ruling R18 -- x86_64 code is never translated, CI included: it runs only on x86_64
#       hardware
# spec: tests/host-cpu-test.sh
host_runs_x86_64() {
  [ "$(uname -s)" = Darwin ] || return 1
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && return 1
  [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ] && return 1
  [ "$(uname -m)" = x86_64 ]
}
runs_natively() {
  [ -f "$1" ] || return 1
  _hc_f="$(file -b "$1" 2>/dev/null)" || return 1
  case "$_hc_f" in Mach-O*) ;; *) return 1 ;; esac
  case "$_hc_f" in *x86_64*) host_runs_x86_64 && return 0 ;; esac
  case "$_hc_f" in *arm64*) [ "$(uname -s)" = Darwin ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && return 0 ;; esac
  return 1
}
arch_runs_natively() {
  case "$1" in
    x86_64) host_runs_x86_64 ;;
    arm64) [ "$(uname -s)" = Darwin ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] ;;
    *) return 1 ;;
  esac
}
jdk_runs_natively() {
  _hc_a="$(sed -n 's/^OS_ARCH="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$1/release" 2>/dev/null | sed -n 1p)"
  case "$_hc_a" in
    x86_64|amd64) _hc_a=x86_64 ;;
    aarch64|arm64) _hc_a=arm64 ;;
    '') ;;
    *) return 1 ;;
  esac
  _hc_f="$(file -bL "$1/bin/java" 2>/dev/null)" || _hc_f=""
  case "$_hc_f" in
    Mach-O*)
      if [ -n "$_hc_a" ]; then
        case "$_hc_f" in *"$_hc_a"*) arch_runs_natively "$_hc_a"; return ;; *) return 1 ;; esac
      fi
      case "$_hc_f" in *x86_64*) arch_runs_natively x86_64 && return 0 ;; esac
      case "$_hc_f" in *arm64*) arch_runs_natively arm64 && return 0 ;; esac
      return 1 ;;
    *)
      [ -z "$_hc_a" ] || { arch_runs_natively "$_hc_a"; return; }
      return 0 ;;
  esac
}
