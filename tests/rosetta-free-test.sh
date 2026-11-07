#!/bin/sh
# platform: host-agnostic -- reads the tracked scripts and workflows; needs git, and python3 with PyYAML for the workflow half (77 without)
# usage: sh tests/rosetta-free-test.sh [ROOT]
#   No x86_64 code executes under Rosetta, CI included (PORT.md ruling R18): x86_64 runs only on x86_64
#   hardware, the 10.9 box and the mavericks-vm guest in practice. A static check: GitHub's arm64 runner has Rosetta, and no
#   signal this repo can read without root says afterwards whether a process ran translated. It fails when
#     - any tracked script or workflow runs arch -x86_64 (or arch -arch x86_64);
#     - a run: step of a job on a macos-* runner runs a JDK's bin/ tool or anything under test-natives/;
#     - a tracked script runs a JDK's bin/ tool as a command (a path ending in /bin/java, keytool, javac...,
#       or "$java" / "$keytool") and is not in the inventory below, or is listed as gated and runs one
#       before its first host-CPU gate (tests/lib/host-cpu.sh's runs_natively or host_runs_x86_64), or is
#       listed as on-target and runs one before refusing every host but Mac OS X 10.9.
#   ROOT defaults to this repo (the mutation cases pass a copy).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
R="${1:-$(cd "$here/.." && pwd)}"
cd "$R"
fail=0
bad() { echo "FAIL $*"; fail=1; }
tools='java|javac|keytool|jshell|jlink|jar|javap|jdeps|jmod|jpackage|jcmd|jfr|jstack|jinfo|jmap|serialver'
code() { awk '{ if ($0 ~ /^[[:space:]]*#/) print ""; else print }' "$1"; }  # FILE's lines with each comment line blanked, so prose never counts and line numbers hold
execs() {  # execs FILE: the line numbers where FILE runs a JDK tool as a command
  code "$1" | grep -nE "(^|[;&|(]|\\\$\\(|then|do|else)[[:space:]]*\"?[^[:space:]\"=]*/bin/($tools)\"?([[:space:]]|\$)|(^|[;&|(]|\\\$\\(|then|do|else)[[:space:]]*\"\\\$(java|keytool|javac)\"" \
    | cut -d: -f1
}
first() { sort -n | sed -n 1p; }

files="$(git ls-files -- '*.sh' '.github/workflows/*.yml')"
for f in $files; do
  if code "$f" | grep -qE '(^|[;&|(]|\$\(|then|do|else|run:)[[:space:]]*(/usr/bin/)?arch[[:space:]]+(-arch[[:space:]]+)?-?x86_64'; then
    bad "$f runs arch -x86_64: x86_64 under Rosetta"
  fi
done

# spec: PORT.md ruling R18 -- every script that runs a JDK's tools, and why that never runs x86_64 translated
inventory='tests/build-jdk-test.sh gated
tests/smoke-runtime.sh gated
tests/jtreg.sh gated
tests/smoke-mavericks.sh on-target
build/toolchain.sh native: the boot JDK, built for this host, and jtreg built with it
tests/boot-jdk-test.sh native: the boot JDK, built for this host
tests/package-manifest-test.sh native: stand-in shell scripts; the real image is expanded, never run
build/package-pkg.sh target: writes the postinstall that runs bin/java on the installing Mac, never runs it'
for f in $(git ls-files -- '*.sh'); do
  case "$f" in tests/lib/host-cpu.sh|tests/rosetta-free-test.sh|tests/host-cpu-test.sh) continue ;; esac
  x="$(execs "$f" | first)"
  [ -n "$x" ] || continue
  kind="$(printf '%s\n' "$inventory" | awk -v f="$f" '$1 == f { print $2 }')"
  case "$kind" in
    gated)
      g="$(code "$f" | grep -nE 'runs_natively|host_runs_x86_64' | cut -d: -f1 | first)"
      [ -n "$g" ] && [ "$g" -le "$x" ] || bad "$f runs a JDK tool at line $x before its host-CPU gate (${g:-none})" ;;
    on-target)
      g="$(code "$f" | grep -nE 'uname -r' | cut -d: -f1 | first)"
      [ -n "$g" ] && [ "$g" -lt "$x" ] || bad "$f runs a JDK tool at line $x before refusing hosts other than Mac OS X 10.9 (${g:-no uname -r})" ;;
    native:|target:) ;;
    *) bad "$f runs a JDK tool at line $x and is not in tests/rosetta-free-test.sh's inventory: gate it with tests/lib/host-cpu.sh, or say why it never runs x86_64 translated" ;;
  esac
done

# platform: shipyard's install action puts PyYAML in the user site (pip --user), which -I hides (it
#           implies -s); -E keeps it while ignoring PYTHON* variables, and -P (3.11+) keeps the current
#           directory off sys.path. The probe and the run take the same flags, so they cannot disagree.
pyflags=-E
if command -v python3 > /dev/null 2>&1 && python3 -E -P -c '' > /dev/null 2>&1; then pyflags="-E -P"; fi
# shellcheck disable=SC2086  # pyflags is one or two fixed flags
if command -v python3 > /dev/null 2>&1 && python3 $pyflags -c 'import yaml' > /dev/null 2>&1; then
  # shellcheck disable=SC2086
  python3 $pyflags - "$tools" $(git ls-files -- '.github/workflows/*.yml') <<'PY' || fail=1
import re, sys, yaml
tools, files = sys.argv[1], sys.argv[2:]
pat = re.compile(r"/bin/(%s)\b|test-natives/|(^|[;&|(]|\$\()\s*(/usr/bin/)?arch\s+(-arch\s+)?-?x86_64" % tools)
bad = 0
for f in files:
    w = yaml.safe_load(open(f)) or {}
    for name, job in (w.get("jobs") or {}).items():
        ro = job.get("runs-on", "")
        ro = " ".join(ro) if isinstance(ro, list) else str(ro)
        if "macos" not in ro:
            continue
        for st in job.get("steps") or []:
            run = st.get("run") or ""
            for line in run.splitlines():
                if line.strip().startswith("#"):
                    continue
                if pat.search(line):
                    print("FAIL %s: job %s (%s) runs x86_64 code on the runner: %s" % (f, name, ro, line.strip()))
                    bad = 1
sys.exit(bad)
PY
else
  echo "SKIP the workflow half: no python3 with PyYAML"
  [ "$fail" = 0 ] && exit 77
fi
[ "$fail" = 0 ] || exit 1
echo "PASS: rosetta-free"
