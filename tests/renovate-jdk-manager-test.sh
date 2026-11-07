#!/bin/sh
# platform: host-agnostic -- needs python3 (none on Mac OS X 10.9); exits 77 without it
# usage: sh tests/renovate-jdk-manager-test.sh
#   Runs .github/renovate.json's jdk manager as Renovate would read it, over the real jdk25u tags in
#   tests/fixtures/jdk25u-ls-remote-tags.txt (EA builds such as jdk-25.0.6+1, GA tags such as
#   jdk-25.0.5-ga, and the CA respins' tags): its matchString must take GA from components/jdk/version,
#   and its allowedVersions, extractVersion and versioning must leave only -ga tags as candidates, the
#   respins among them, ordered so that the newest is jdk-25.0.5.0.3-ga. Renovate's own validator is
#   not run here.
set -eu
command -v python3 > /dev/null 2>&1 || { echo "SKIP renovate-jdk-manager: no python3"; exit 77; }
here="$(cd "$(dirname "$0")" && pwd)"
python3 -I - "$here/../.github/renovate.json" "$here/../components/jdk/version" "$here/fixtures/jdk25u-ls-remote-tags.txt" <<'PY'
import json, re, sys
cfg, pin, tags = sys.argv[1:4]
def fail(m): print("FAIL " + m); sys.exit(1)
def js(r): return r.replace("(?<", "(?P<")
def slashed(r): return r[1:-1] if r.startswith("/") and r.endswith("/") else r
d = json.load(open(cfg))
ms = [m for m in d["customManagers"] if any(re.search(slashed(p), "components/jdk/version") for p in m["managerFilePatterns"])]
if len(ms) != 1: fail("%d managers match components/jdk/version, not one" % len(ms))
m = ms[0]
if m.get("datasourceTemplate") != "github-tags": fail("the jdk manager's datasource is %r" % m.get("datasourceTemplate"))
got = None
for s in m["matchStrings"]:
    mo = re.search(js(s), open(pin).read())
    if mo: got = mo.groupdict()
if not got: fail("no matchString matches components/jdk/version")
ga = re.search(r"^GA=(\S+)$", open(pin).read(), re.M).group(1)
if got.get("currentValue") != ga: fail("the manager takes %r, not GA %r" % (got.get("currentValue"), ga))
if got.get("depName") != "openjdk/jdk25u": fail("the manager's depName is %r" % got.get("depName"))
if "currentDigest" in got: fail("the manager also moves a digest; DIGEST is the pins bot's")
rules = [r for r in d["packageRules"] if "openjdk/jdk25u" in r.get("matchDepNames", [])]
if len(rules) != 1 or "allowedVersions" not in rules[0]: fail("no single allowedVersions rule for openjdk/jdk25u")
allowed = re.compile(slashed(rules[0]["allowedVersions"]))
ver = re.compile(js(m["versioningTemplate"][len("regex:"):]))
ext = re.compile(js(m["extractVersionTemplate"]))
names = sorted({l.split()[1][len("refs/tags/"):].replace("^{}", "") for l in open(tags) if l.strip()})
cand = [n for n in names if ext.match(n) and allowed.match(n) and ver.match(n)]
for n in cand:
    if not n.endswith("-ga"): fail("a candidate is not a GA tag: %s" % n)
for must in ["jdk-25.0.5-ga", "jdk-25.0.5.0.2-ga", "jdk-25.0.5.0.3-ga", "jdk-25.0.4.1-ga"]:
    if must not in cand: fail("%s is not a candidate: %s" % (must, cand))
for never in ["jdk-25.0.6+1", "jdk-25.0.6+0", "jdk-25.0.5.1+1", "jdk-25.0.5+8", "jdk-25.0.5.0.3+1"]:
    if never in names and never in cand: fail("%s, a build tag, is a candidate" % never)
    if never not in names: fail("the fixture lacks %s" % never)
if not ver.match(ga): fail("the versioning cannot read the pinned GA %s" % ga)
key = lambda n: tuple(int(ver.match(n).group(k) or 0) for k in ("major", "minor", "patch", "build"))
order = sorted(cand, key=key)
if order[-1] != "jdk-25.0.5.0.3-ga": fail("the newest candidate is %s, not jdk-25.0.5.0.3-ga: %s" % (order[-1], order))
if not key("jdk-25.0.5.0.3-ga") > key("jdk-25.0.5.0.2-ga") > key("jdk-25.0.5-ga") > key("jdk-25.0.4.1-ga"):
    fail("the respins do not order after their update: %s" % order)
for later in ["jdk-25.0.5.1-ga", "jdk-25.0.6-ga", "jdk-25.0.10-ga"]:
    if not (allowed.match(later) and ver.match(later) and key(later) > key("jdk-25.0.5.0.3-ga")):
        fail("a later GA, %s, would not be proposed over jdk-25.0.5.0.3-ga" % later)
for other in ["jdk-26-ga", "jdk-26.0.1-ga", "jdk-25-ga", "jdk-25.0.6-ea-ga"]:
    if allowed.match(other) and ver.match(other): fail("%s would be proposed" % other)
print("PASS: renovate-jdk-manager (%d GA candidates from %d tags; newest %s)" % (len(cand), len(names), order[-1]))
PY
