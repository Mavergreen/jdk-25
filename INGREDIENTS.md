# Build ingredients

Everything baked into the shipped `.pkg`, and how a change to it reaches a release. An *ingredient*
is an input to the product; the *own upstream* is the thing this repo exists to port.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| OpenJDK 25 source (own upstream) | `components/jdk/version` `GA` (a jdk25u `-ga` tag); `REF` and `DIGEST` are the build tag and commit `scripts/resolve-ga.sh` finds for it; `UPSTREAM_VERSION` is derived from `REF` by `build/derive-upstream-version.sh`, which refuses a `REF` that is not `GA`'s, and is not committed | the jdk regex manager below moves `GA` alone, `-ga` tags only | `.github/workflows/pins-bot.yml` fills `REF`, `DIGEST` and `TARBALL_SHA256` on the branch; then `release.yml` on push to main cuts `-mavericks.1` |
| OpenJDK 25 source tarball (`openjdk/jdk25u` at `DIGEST`) | `components/jdk/version` (`GA`, `REF`, `DIGEST`, `TARBALL_SHA256`) | `.github/renovate.json` regex manager moves `GA` alone, jdk25u `-ga` tags only (CA respins such as `jdk-25.0.5.0.3-ga` included; EA build tags never) | `.github/workflows/pins-bot.yml` fills `REF` and `DIGEST` (`scripts/resolve-ga.sh`) and `TARBALL_SHA256` (`scripts/pin-source-tarballs.sh`) on the branch; until it has, every build refuses to start, then `release.yml` |
| Boot JDK (Temurin 25 GA, macOS aarch64 tar.gz; build only, ships nothing) | `components/bootjdk/version` (`TAG`, `SHA256`) | `.github/renovate.json` regex manager, `github-release-attachments` on `adoptium/temurin25-binaries`, capped `<26`; moves `TAG` and `SHA256` together | a bump re-runs CI and cross-builds with the new boot JDK; on 10.9 the boot JDK is our own `/usr/local/mavergreen/jdk25` |
| clang22 | `components/clang22/version` | `.github/renovate.json` regex manager on `Mavergreen/clang-22` releases (`-mavericks.N`) | `release.yml` cuts the next `-mavericks.N` |
| Recaulk | `components/recaulk/version` | shipyard's shared preset (no local manager) | `release.yml` cuts the next `-mavericks.N` |
| CA roots (`lib/security/cacerts`, from the family ca-certs release's `share/ca-certs/trusted`: the roots of its `ca-certificates.crt`) | `components/ca-certs/version` | `.github/renovate.json` regex manager on `Mavergreen/ca-certs` releases (`-mavericks.N`) | `release.yml` cuts the next `-mavericks.N` with the new roots |
| pandoc (build only, ships nothing: configure makes the man pages with it) | `components/pandoc/version` (`VERSION`, `SHA256` of the macOS arm64 zip) | `.github/renovate.json` regex manager, `github-release-attachments` on `jgm/pandoc`; moves `VERSION` and `SHA256` together | a bump rebuilds the man pages; no pinned pandoc runs on Mac OS X 10.9 (3.13's x86_64 build needs macOS 15), so a native 10.9 build has no man pages |
| jtreg (test only, ships nothing: `tests/jtreg.sh` runs the conformance subset with it) | `components/jtreg/version` (`TAG`, `SHA256` of GitHub's tarball of `TAG`); held at the `JTREG_VERSION` the pinned jdk25u's `make/conf/github-actions.conf` names, which `release.yml`'s `source` job checks (`scripts/check-jtreg-pin.sh`), so a jdk bump that leaves jtreg behind fails before it builds | `.github/renovate.json` regex manager, `github-tags` on `openjdk/jtreg`; moves `TAG` only and never automerges: merge only to match jdk25u, writing `SHA256` by hand | `build/toolchain.sh`'s `jdk_jtreg` builds the tarball (no binaries are published); re-run `tests/jtreg.sh` on Mac OS X 10.9; releases nothing |
| Previous jdk-25 release (test only, ships nothing: `tests/smoke-mavericks.sh`'s upgrade leg installs it before the candidate) | `components/previous-release/version` (a release tag, or `none` until the first release exists) | `.github/renovate.json` regex manager, `github-releases` on `Mavergreen/jdk-25`; matches only a version, so it proposes nothing while the pin reads `none` | write the first release's tag here by hand once it is published; after that, re-run `tests/smoke-mavericks.sh` on Mac OS X 10.9; releases nothing |
| longboat (CI only; build only, ships nothing) | `components/longboat/version` | `.github/renovate.json` regex manager on `Mavergreen/longboat` releases | re-runs CI, releases nothing |

## Declared state

- upstream: components/jdk/version:GA
- jdk-source: components/jdk/version
- bootjdk: components/bootjdk/version
- clang22: components/clang22/version
- recaulk: components/recaulk/version
- ca-certs: components/ca-certs/version
- pandoc: components/pandoc/version

## Conformance deviations

- sdk-pin:*/lib/libawt_lwawt.dylib: uses AppKit declarations from 10.10-11.0 that the 10.9 SDK lacks, so it compiles and links against the pinned 11.3 SDK at deployment target 10.9 (patches/0014; the compat guard still checks its imports and selectors against 10.9); exit: the family SDK declaration facility (Recaulk recipes + shipyard VFS materializer, mavergreen-iterm2 design) widened to the JDK's AppKit use; then this line is deleted
- sdk-pin:*/lib/libosxapp.dylib: uses AppKit declarations from 10.10-11.0 that the 10.9 SDK lacks, so it compiles and links against the pinned 11.3 SDK at deployment target 10.9 (patches/0014; the compat guard still checks its imports and selectors against 10.9); exit: the family SDK declaration facility (Recaulk recipes + shipyard VFS materializer, mavergreen-iterm2 design) widened to the JDK's AppKit use; then this line is deleted
- sdk-pin:*/lib/libosxui.dylib: uses AppKit declarations from 10.10-11.0 that the 10.9 SDK lacks, so it compiles and links against the pinned 11.3 SDK at deployment target 10.9 (patches/0014; the compat guard still checks its imports and selectors against 10.9); exit: the family SDK declaration facility (Recaulk recipes + shipyard VFS materializer, mavergreen-iterm2 design) widened to the JDK's AppKit use; then this line is deleted
- sdk-pin:*/lib/libsplashscreen.dylib: uses AppKit declarations from 10.10-11.0 that the 10.9 SDK lacks, so it compiles and links against the pinned 11.3 SDK at deployment target 10.9 (patches/0014; the compat guard still checks its imports and selectors against 10.9); exit: the family SDK declaration facility (Recaulk recipes + shipyard VFS materializer, mavergreen-iterm2 design) widened to the JDK's AppKit use; then this line is deleted
- install-path:Library/Java/JavaVirtualMachines/*: 10.9's java_home and JavaVM stubs look only here
- macos-runner:release.yml:tests: run-repo-tests runs macOS-only tests: package-manifest-test reads its plists with PlistBuddy, and the toolchain and boot-JDK tests expand the clang22-cross pkg and run the Temurin macOS aarch64 boot JDK. Exit: those tests' tools have Linux equivalents in shipyard (stevedore plist, a Linux boot JDK pin), and the job moves to ubuntu-latest.
- macos-runner:release.yml:build: build/build-jdk.sh runs the Temurin macOS aarch64 boot JDK and the clang22-cross pkg, both macOS-only, and the serviceability agent's stubs come from Apple's mig (patches/0008). Exit: a Linux boot JDK pin, clang22 on a Linux host, and mig's stubs generated without Apple's tool; then the build moves to ubuntu-latest.
- macos-runner:release.yml:package: build/build-updater.sh compiles the updater with clang22-cross and build/package-pkg.sh and its test read plists with PlistBuddy. Exit: the updater builds with clang22 on Linux, as other family repos already do, and packaging reads plists with stevedore only.
- on-target:gui: AWT/Swing/Java2D not built (headless-only); exit: release 2's Swing smoke (plan Task 20)
