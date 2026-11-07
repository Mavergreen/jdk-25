# platform: host-agnostic -- sourced, never run: uname, sysctl and file(1) only, with no shipyard, so the 10.9 guest can source it
#   usage: . tests/lib/host-cpu.sh; host_runs_x86_64; runs_natively FILE
#          Decides by the host's CPU, never by executing what it asks about. host_runs_x86_64 is true on a
#          Darwin host that runs x86_64 natively: no arm64 hardware (hw.optional.arm64 absent or 0), not a
#          process Rosetta translates (sysctl.proc_translated absent or 0, since a translated shell's uname -m
#          says x86_64), and uname -m x86_64. Mac OS X 10.9 has neither sysctl, and is such a host.
#          runs_natively FILE is true when FILE is a Mach-O (file(1)) with a slice this host runs untranslated:
#          x86_64 only where host_runs_x86_64, arm64 only on arm64 hardware.
# spec: PORT.md ruling R18 -- x86_64 code executes only natively on Mac OS X 10.9 or in the mavericks-vm
#       guest; never under Rosetta, CI included
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
