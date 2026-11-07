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
and `--disable-cds-archive` (PORT.md ruling R55).

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
beside it. Use the artifact from the cross build of the same commit, then run:

```sh
sh build/compare-builds.sh CROSS_DIR/image "$MAVERICKS_BUILD_ROOT/jdk-25/image"
```

It exits 0 when all of these hold:

- the two `build-info.txt` files agree on every key both have;
- both images pass the compat guard, including the Mach-O inside the jmods;
- the files in each image, and the entries in each jmod, are the same.

Some differences are expected and don't fail the run:

- **Mach-O bytes:** reported as `Mach-O differs`.
- **Other files' bytes:** reported as `differs (not Mach-O)`. These follow from Mach-O differences:
  the jmods' module hashes cover their natives.
- **Differences by design (R55):** `host`, `bootjdk`, and the man pages of a `pandoc=none` build. Each
  is reported as `excused`.

Anything else is a finding to fix before the native build is trusted.
