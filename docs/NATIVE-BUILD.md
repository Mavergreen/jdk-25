# Building jdk25 natively on Mac OS X 10.9

Every release is cross-built on an arm64 Mac. This document covers the same build run on a real
Mac OS X 10.9.5 box, and how to check that the two agree. A native build is how we find out whether
the cross build's inputs and assumptions hold up.

`build/build-jdk.sh` is the one recipe for both. On 10.9 (`jdk_host_is_109` in `build/toolchain.sh`)
it changes three things:

- **Boot JDK:** the installed `/usr/local/mavergreen/jdk25` (`jdk_boot_jdk`). The cross build uses the
  Temurin aarch64 build pinned in `components/bootjdk/version`.
- **Compiler:** the installed `/usr/local/mavergreen/clang22` (`jdk_toolchain`). It must be exactly
  the release `components/clang22/version` pins.
- **Target:** configure gets no `--openjdk-target` (`jdk_target_args`), because the build machine is
  also the target.

Everything else is the same: the source, the patches, the pinned 10.9 SDK, Recaulk, ca-certs, the flags,
`--disable-cds-archive` (PORT.md ruling R55), and `TZ=UTC` (R58). Where upstream's own build differs
between native and cross, `patches/0020` makes the native build do what the cross build does (R59).

## Prerequisites

On the 10.9.5 box:

| What | Why |
|---|---|
| The Command Line Tools for 10.9 (`/usr/bin/clang`, `otool`, `nm`, `lipo`, `git`) | `jdk_autoconf` builds autoconf and m4 with `/usr/bin/clang`, configure's build tools use it, and the compat guard reads Mach-O with the others |
| shipyard, installed from its pkg | `build/msc.sh` finds its scripts (`fetch_sdk.sh`, `mavericks_fetch.sh`, `fetch_product_pkg.sh`, the compat guard) |
| `jdk25` release 1 (`25.0.5.0.3-mavericks.1`), installed from its pkg | the boot JDK, at `/usr/local/mavergreen/jdk25` |
| `clang22` at the release `components/clang22/version` pins (`22.1.8-mavericks.12` today), installed from its pkg | the compiler, `ld64.lld` and libc++, at `/usr/local/mavergreen/clang22`; `jdk_toolchain` refuses any other release |
| A network connection | the build fetches the pinned jdk25u source, the 10.9 and 11.3 SDKs, Recaulk, ca-certs, autoconf and m4, each checked against its pinned SHA-256 |

You don't install anything else:

- **GNU make:** configure accepts the 10.9 `/usr/bin/make`, GNU Make 3.81. The arm64 runners that
  cross-build releases have the same version: their configure logs `Using GNU make at /usr/bin/make
  (version: GNU Make 3.81)`. If a `gmake` is on PATH (the family `make` product), configure checks that
  one instead, while `build/build-jdk.sh` still runs `make`.
- **autoconf and m4:** `jdk_autoconf` builds the pinned GNU autoconf (`components/autoconf/version`)
  and GNU m4 (`components/m4/version`) into the build root and hands them to configure (PORT.md ruling
  R53). Don't install a family product or pkgsrc's autoconf. The QUEUE entry "shipyard: a pinned
  autoconf/m4 facility" plans to move this into shipyard for every autotools product.
- **The SDKs:** shipyard's `fetch_sdk.sh` fetches its own pinned copies into its cache. An SDK that
  `longboat sdk install` put elsewhere isn't read.
- **pandoc:** no pinned pandoc runs on 10.9, so a native build has no man pages (PORT.md ruling R19).

Keep the build root on local disk. It defaults to `$TMPDIR/mm-build`. Set `MAVERICKS_BUILD_ROOT` to
move it, never into an NFS-mounted checkout.

## Build

From a clone at the commit you want to check:

```sh
sh build/build-jdk.sh
```

It leaves the image at `$MAVERICKS_BUILD_ROOT/jdk-25/image`, with `build-info.txt` beside it. Its
`host` line records where it was built, and its `bootjdk` line records `jdk25-<version>`.

## Compare with the cross build

CI's `image` artifact unpacks to the same layout as the native build: `image/` with `build-info.txt`
beside it. Use the artifact from the cross build of the same commit if CI made one. Otherwise a
release's artifact works too, with the caveat below. Then run:

```sh
sh build/compare-builds.sh CROSS_DIR/image "$MAVERICKS_BUILD_ROOT/jdk-25/image"
```

It exits 0 when all of these hold:

- the two `build-info.txt` files agree on every key both have;
- both images pass the compat guard, including the Mach-O inside the jmods;
- the files in each image, and the entries in each jmod, jar and zip, are the same;
- each of those files and entries has the same bytes, apart from the exceptions below.

An archive's own bytes aren't compared, only its entries, because configure stamps the entries with
its own time. That holds for an archive inside a jmod too (`jdk.compiler`'s `lib/ct.sym`).

Some differences are expected and don't fail the run:

- **Mach-O bytes:** reported as `Mach-O differs`.
- **What records Mach-O hashes:** `lib/modules` and `java.base`'s `module-info.class` (ModuleHashes).
  These are excused only when a Mach-O differs, and reported as `excused (records Mach-O hashes)`.
- **Differences by design (R55):** `host`, `bootjdk`, and the man pages of a `pandoc=none` build. Each
  is reported as `excused`.
- **What the boot JDK writes (R55):** a jar manifest's `Created-By` line, when `bootjdk` differs,
  reported as `excused (bootjdk's jar wrote it)`. The rest of the manifest is compared.

Any other byte difference is reported as `differs (not Mach-O)` and fails the run. Each failure is a
finding to fix before the native build is trusted.

A key only one `build-info.txt` has is reported as `only cross has KEY (not compared)` or `only native
has KEY (not compared)`. An image built before `host` was recorded has no `host` key, so against it
`host` is reported that way instead of as `excused`.

CI makes an `image` artifact only for a pushed commit, and it expires after a while. If the commit you
built has none, the nearest is a release's artifact, but then the comparison spans every change between
the two commits as well, so a PASS says less. The pass recorded below is one of those: a same-commit
comparison hasn't been done yet.

Neither a pass nor a failure changes `INGREDIENTS.md`, which records no deviation for the native
build. Checking every commit this way needs the scheduled native build job, and that is still a QUEUE
entry.

## Recorded passes

### 2026-11-07: 528183f against release 1

- **Native:** commit 528183f, built on Mac OS X 10.9.5 (`host=x86_64-macos10.9.5`), booted by
  `jdk25-25.0.5.0.3+1-mavericks.1`, with `clang22=22.1.8-mavericks.12`. `build/build-jdk.sh` exited 0,
  and the native `java -version` runs.
- **Cross:** release 1's CI `image` artifact, commit cb771d1 (CI run 42377643341). 528183f wasn't
  pushed, so CI had made no artifact for it. Between the two commits, the changes that reach a cross
  build are:
  - `--disable-cds-archive`, which changes nothing in the image, since a cross build makes no CDS archive;
  - `build-info.txt`'s new `host` key and its `bootjdk` value.

  Everything else is native-only.
- **Result:** `compare-builds: PASS: the native image agrees with the cross image`, exit 0. Both images
  pass the compat guard with 145 Mach-O files each, and all 145 differ (72 in the image, 73 inside the
  jmods). The `features` lines are identical, `zgc` and `dtrace` included. That comparison is between
  the two `build-info.txt` files, staged in the maintainer's `shared-trees/mm-transfer` as
  `cross-build-info-cb771d1.txt` and `native-build-info-528183f.txt`.
- **Excused:**
  - `bootjdk` (R55);
  - `pandoc` and the 58 man pages a `pandoc=none` build lacks: 29 in `man/man1` and 29 inside the jmods
    (R55, R19);
  - the `Created-By` line in 13 jar manifests, the 11 `demo/jfc` jars and `lib/jrt-fs.jar` both on its own
    and inside `java.base.jmod` (R55);
  - `java.base.jmod`'s `module-info.class` and `lib/modules`, which record Mach-O hashes (R55).

  `host` was reported as only on the native side, as above.
- **What made the rest agree:** each of these fixed a native difference; none of them is an excusal.
  - **R57:** on 10.9, configure's `CODESIGN` is a shim that 10.9's codesign tools can follow, so the native
    build gets through signing at all.
  - **R58:** `TZ=UTC` makes `lib/classlist` match.
  - **R59:** `patches/0020` makes the 68 jmods' `module-info.class` match.
- **`lib/modules` by hand:** both sides' `lib/modules` were extracted with `jimage extract` and
  compared. Ten entries differ, and each records or is a Mach-O:
  - `java.base/module-info.class`;
  - the 8 `SystemModules$*` classes, which differ only in one byte-array literal each, the module
    hashes;
  - `jpackageapplauncher`, a Mach-O that the guard also checks through its jmod.

  Nothing else differs, so the excusal hid nothing in this pass.
