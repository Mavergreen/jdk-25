# Porting notes

Each change this port carries on top of the upstream OpenJDK source is explained here: what it does,
why 10.9 needs it, where it came from (provenance), and what would let us drop it (exit).

Many of the patches derive from [Hiker159/jdk-macos-legacy](https://github.com/Hiker159/jdk-macos-legacy)
(GPLv2), which ports JDK 25 to older macOS releases. Thanks to its author.

## Changes

Applied in order by shipyard's `apply_patches.sh` (`patch -p1 -F 0 -N -V none`), from `build/build-jdk.sh`. Each patch's header gives
what, why on 10.9, provenance and exit.

| Patch | What | Exit |
|---|---|---|
| `patches/0001-build-deployment-target-10.9.patch` | x86_64 deployment target 10.9 | never |
| `patches/0002-build-no-metal.patch` | no Metal in configure, link or shaders | never |
| `patches/0003-hotspot-no-map-jit-on-x86_64.patch` | `MAP_JIT` only on aarch64 | never on x86_64 |
| `patches/0004-java-props-os-version-guard.patch` | `os.version` without `-[NSProcessInfo operatingSystemVersion]` | Recaulk back-fills the method |
| `patches/0005-nio-udp-disconnect-bsd.patch` | UDP disconnect without `disconnectx` | Recaulk back-fills `disconnectx` |
| `patches/0006-desktop-launchservices.patch` | `Desktop` opens via LaunchServices before 10.15 | never |
| `patches/0007-nio-no-secure-directory-stream-on-10.9.patch` | no `SecureDirectoryStream` where libSystem lacks `renameat` (10.9), checked at run time | Recaulk gains an fd-relative `renameat`, then delete this patch |
| `patches/0008-build-mig-target-arch.patch` | `mig -arch <target>` for the serviceability agent's `mach_exc` stubs | upstream passes the target arch to mig |
| `patches/0009-hotspot-memmap-vm-memory-tags.patch` | memory-map printer skips `VM_MEMORY_*` tags the 10.9 SDK lacks | never |
| `patches/0010-hotspot-thread-name-size-header.patch` | `MAXTHREADNAMESIZE` from `<sys/proc_info.h>` | never |
| `patches/0011-nio-clone-noownercopy.patch` | `CLONE_NOOWNERCOPY` where `<sys/clonefile.h>` lacks it | Recaulk defines it |
| `patches/0012-java-props-os-version-declaration.patch` | declares `-[NSProcessInfo operatingSystemVersion]` for `0004` against the 10.9 SDK | with `0004`: a Recaulk back-fill |
| `patches/0013-default-headless-on-10.9.patch` | `java.awt.headless` defaults to true on macOS (ruling R10) | the GUI release's gating commit |
| `patches/0014-build-appkit-natives-sdk.patch` | the four AppKit natives build against `MAVERGREEN_APPKIT_SDK` (the 11.3 pin) at 10.9 (ruling R16) | the family SDK declaration facility widened to AppKit |
| `patches/0015-java2d-opengl-only.patch` | Java2D uses OpenGL, never Metal (was `patches-gui/0001`) | never |
| `patches/0016-appkit-system-colors.patch` | system colors without 10.14 selectors (was `patches-gui/0004`) | never |
| `patches/0017-nio-kqueue-selector-ignores-urgent-only-reads.patch` | the kqueue `Selector` ignores a read event that reports only urgent data while `SO_OOBINLINE` is off: it discards the byte and makes the socket's read filter `EV_CLEAR` until real data or EOF, so `select` neither selects the key, nor returns early, nor spins inside (ruling R26) | none while 10.9 is supported |
| `patches/0018-nio-normalize-paths-before-apfs.patch` | `jdk.nio.path.useNormalizationFormD` defaults to true before macOS 10.13 (HFS+ only); an explicit `-D` still decides (ruling R27) | none while 10.9 is supported |

Parked for release 2, not applied (`patches-gui/`, same headers): `0002-appkit-nsstring-substring`,
`0003-appkit-window-tabbing-fullsize`, `0005-appkit-tray-icon-nsbutton`, `0006-a11y-legacy-superclass`,
`0007-a11y-subrole-guards`. They apply in that order on top of `patches/`.

Not a patch: every target link takes clang22's own `libc++.a`, hidden, plus the system `libc++abi`
(`-nostdlib++ -Wl,-load_hidden,<clang22>/lib/libc++.a -lc++abi` in `build/build-jdk.sh`'s
`--with-extra-ldflags`, ruling R21), as clang22's own linker wrapper does. The C++ code compiles
against clang22's libc++ headers, and the 10.9 SDK's libc++ lacks instantiations they expect.
The same flags reach the C-only libraries too, so every link also passes `-Wl,-dead_strip_dylibs`,
and only a binary that takes a symbol from `libc++abi` keeps its load command.

Not a patch: `lib/security/cacerts` holds the family ca-certs release's trusted roots
(`--with-cacerts-src`, ruling R34), so each alias is that bundle's fingerprint file name, such as
`cabd2a79a1076a31f21d253635cb039d4329a5e8.pem [jdk]` for ISRG Root X1, not upstream's friendly name
(`letsencryptisrgx1 [jdk]`). A script that looks a root up by upstream's alias finds nothing.

Not a patch: 10.9's `/usr/libexec/java_home` and `/usr/bin` Java stubs list a JDK bundle only when its
`Info.plist` has `CFBundleExecutable` and `Contents/MacOS` holds that file, so
`build/jdk-bundle-Info.plist.in` names `libjli.dylib` and `build/package-pkg.sh` links
`Contents/MacOS/libjli.dylib` to `../Home/lib/libjli.dylib`; either one alone is not listed (ruling R44).

Recaulk provides, with no JDK patch: `clock_gettime`, `clonefile`, `futimens`, `utimensat`,
`fchmodat`, `openat`, `fstatat`, `fdopendir`, `unlinkat`, `renameat` (see the classification below).
Its `renameat` is not fd-relative across two directories, so `patches/0007` keeps
`SecureDirectoryStream` off on 10.9; an fd-relative `renameat` in Recaulk is that patch's exit.

## Prior art read

Hiker159/jdk-macos-legacy at commit `70d25ea1d6f7292c8e926e9efe112f949800ae10` (its `main` on
2026-11-03): `patches/25/mavericks.patch` (48 hunks over 25 files, against `jdk-25.0.4.1+1`, the
tag this repo pins) and `docs/MAVERICKS.md`. The patch applies cleanly to our pinned tree. Every hunk
is classified below into one of three classes:

- **Recaulk**: the hunk exists only because 10.9's libSystem lacks a generic function. Recaulk
  provides the function, so the JDK carries no patch for it; the JDK links Recaulk instead.
- **JDK-headless**: a JDK-specific change the headless release needs. Carried in `patches/`, applied
  by shipyard's `apply_patches.sh`.
- **JDK-GUI**: AppKit, Java2D or accessibility. Parked in `patches-gui/` (not applied) for release 2.

Hiker159's build also passes `--with-jvm-features=-zgc` (ZGC excluded; `docs/MAVERICKS.md`). We do
not: ZGC builds against the 10.9 SDK unpatched, and jtreg `gc/z` and `tier1_gc_2` pass natively on
10.9.5 (its one new import, `mach_vm_remap`, is in 10.9's libsystem_kernel).

## Hunk classification

Hunks are numbered in the order they appear for each file in `mavericks.patch`.

| File | Hunk | Summary | Class | Destination | Exit |
|---|---|---|---|---|---|
| `make/autoconf/flags.m4` | 1/1 | x86_64 `MACOSX_VERSION_MIN` 10.9.0 (aarch64 keeps 11.00.00) | JDK-headless | `patches/0001-build-deployment-target-10.9.patch` | never: upstream's floor is 11 |
| `make/autoconf/toolchain.m4` | 1/1 | configure no longer requires `metal`/`metallib` | JDK-headless | `patches/0002-build-no-metal.patch` | never: no Metal on 10.9 |
| `make/modules/java.desktop/lib/AwtLibraries.gmk` | 1/4 | `libawt` stops linking `-framework Metal` | JDK-headless | `patches/0002-build-no-metal.patch` | never |
| `make/modules/java.desktop/lib/AwtLibraries.gmk` | 2/4 | `libawt_lwawt` drops the `java2d/metal` header dir | JDK-headless | `patches/0002-build-no-metal.patch` | never |
| `make/modules/java.desktop/lib/AwtLibraries.gmk` | 3/4 | `libawt_lwawt` excludes the `java2d/metal` sources | JDK-headless | `patches/0002-build-no-metal.patch` | never |
| `make/modules/java.desktop/lib/AwtLibraries.gmk` | 4/4 | `libawt_lwawt` stops linking `-framework Metal` | JDK-headless | `patches/0002-build-no-metal.patch` | never |
| `make/modules/java.desktop/lib/ClientLibraries.gmk` | 1/3 | `libsplashscreen` stops linking `-framework Metal` | JDK-headless | `patches/0002-build-no-metal.patch` | never |
| `make/modules/java.desktop/lib/ClientLibraries.gmk` | 2/3 | no `shaders.metal` → `shaders.metallib` compile | JDK-headless | `patches/0002-build-no-metal.patch` | never |
| `make/modules/java.desktop/lib/ClientLibraries.gmk` | 3/3 | `libosxui` stops linking Metal and depending on the shaders | JDK-headless | `patches/0002-build-no-metal.patch` | never |
| `src/hotspot/os/bsd/legacy_macos_clock.hpp` | 1/1 | new header: `clock_gettime` for `CLOCK_REALTIME`/`CLOCK_MONOTONIC` from `gettimeofday` + `mach_absolute_time` | Recaulk | `clock_gettime` | already in Recaulk (macports-legacy-support `time.c`) |
| `src/hotspot/os/bsd/os_bsd.cpp` | 1/1 | `anon_mmap`: `MAP_JIT` only on macOS/aarch64 | JDK-headless | `patches/0003-hotspot-no-map-jit-on-x86_64.patch` | never on x86_64 |
| `src/hotspot/os/bsd/os_perf_bsd.cpp` | 1/2 | include the clock header, `LEGACY_CLOCK_GETTIME` macro | Recaulk | `clock_gettime` | already in Recaulk |
| `src/hotspot/os/bsd/os_perf_bsd.cpp` | 2/2 | `now_in_nanos` uses the macro | Recaulk | `clock_gettime` | already in Recaulk |
| `src/hotspot/os/posix/os_posix.cpp` | 1/5 | include the clock header, macro | Recaulk | `clock_gettime` | already in Recaulk |
| `src/hotspot/os/posix/os_posix.cpp` | 2/5 | `to_abstime` (timed waits) uses the macro, same clock id | Recaulk | `clock_gettime` | already in Recaulk |
| `src/hotspot/os/posix/os_posix.cpp` | 3/5 | `javaTimeMillis` uses the macro | Recaulk | `clock_gettime` | already in Recaulk |
| `src/hotspot/os/posix/os_posix.cpp` | 4/5 | `javaTimeSystemUTC` uses the macro | Recaulk | `clock_gettime` | already in Recaulk |
| `src/hotspot/os/posix/os_posix.cpp` | 5/5 | `javaTimeNanos` uses the macro | Recaulk | `clock_gettime` | already in Recaulk |
| `src/java.base/macosx/native/libjava/java_props_macosx.c` | 1/1 | `os.version`: guard `-[NSProcessInfo operatingSystemVersion]` (10.10+) with `respondsToSelector:`, else upstream's `SystemVersion.plist` fallback | JDK-headless | `patches/0004-java-props-os-version-guard.patch` | a Recaulk back-fill of `-[NSProcessInfo operatingSystemVersion]` |
| `src/java.base/macosx/native/libnio/fs/BsdNativeDispatcher.c` | 1/2 | include `<dlfcn.h>` | Recaulk | `clonefile` | already in Recaulk (macports-legacy-support `clonefile.c`, returns `ENOTSUP`) |
| `src/java.base/macosx/native/libnio/fs/BsdNativeDispatcher.c` | 2/2 | `clonefile` via `dlsym`, `ENOTSUP` when absent so `Files.copy` falls back | Recaulk | `clonefile` | already in Recaulk |
| `src/java.base/macosx/native/libnio/fs/legacy_macos_fs.h` | 1/1 | new header: `futimens`/`utimensat`/`fchmodat` fallbacks over `futimes`/`utimes`/`lutimes`/`chmod`/`lchmod` | Recaulk | `futimens`, `utimensat`, `fchmodat` | already in Recaulk (macports-legacy-support `utimensat.c`, `atcalls.c`) |
| `src/java.base/unix/native/libnio/ch/DatagramChannelImpl.c` | 1/2 | `disconnect0`: drop the `disconnectx` (10.11+) branch, use BSD `connect` | JDK-headless | `patches/0005-nio-udp-disconnect-bsd.patch` | a Recaulk back-fill of `disconnectx` |
| `src/java.base/unix/native/libnio/ch/DatagramChannelImpl.c` | 2/2 | treat `EADDRNOTAVAIL` from that `connect` as success on Apple too | JDK-headless | `patches/0005-nio-udp-disconnect-bsd.patch` | as above |
| `src/java.base/unix/native/libnio/fs/UnixNativeDispatcher.c` | 1/6 | include the fs header, `my_futimens`/`my_utimensat`/`my_fchmodat` pointers | Recaulk | `futimens`, `utimensat`, `fchmodat` | already in Recaulk |
| `src/java.base/unix/native/libnio/fs/UnixNativeDispatcher.c` | 2/6 | resolve those three by `dlsym`, else the fallbacks | Recaulk | `futimens`, `utimensat`, `fchmodat` | already in Recaulk |
| `src/java.base/unix/native/libnio/fs/UnixNativeDispatcher.c` | 3/6 | `openat`/`fstatat$INODE64`/`fdopendir$INODE64` by `dlsym` instead of direct reference, so `SecureDirectoryStream` is off on 10.9 | JDK-headless | replaced by our `patches/0007-nio-no-secure-directory-stream-on-10.9.patch` (run-time check; the symbols themselves come from Recaulk: macports-legacy-support `atcalls.c`, `statxx.c`, `fdopendir.c`, Recaulk's `fdopendir_permissions.c`) | Recaulk gains an fd-relative `renameat`, then delete the patch |
| `src/java.base/unix/native/libnio/fs/UnixNativeDispatcher.c` | 4/6 | `chmod0` calls `my_fchmodat` | Recaulk | `fchmodat` | already in Recaulk |
| `src/java.base/unix/native/libnio/fs/UnixNativeDispatcher.c` | 5/6 | `futimens0` calls `my_futimens` | Recaulk | `futimens` | already in Recaulk |
| `src/java.base/unix/native/libnio/fs/UnixNativeDispatcher.c` | 6/6 | `utimensat0` calls `my_utimensat` | Recaulk | `utimensat` | already in Recaulk |
| `src/java.desktop/macosx/classes/sun/java2d/MacOSFlags.java` | 1/1 | Java2D: Metal never enabled, OpenGL required | JDK-headless | `patches/0015-java2d-opengl-only.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/AWTSurfaceLayers.m` | 1/2 | drop `CAMetalLayer.h` import | JDK-headless | `patches/0015-java2d-opengl-only.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/AWTSurfaceLayers.m` | 2/2 | repaint only `CAOpenGLLayer`s | JDK-headless | `patches/0015-java2d-opengl-only.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/AWTView.m` | 1/2 | `keyDown:`: `containsString:` (10.10+) → `rangeOfString:` | JDK-GUI | `patches-gui/0002-appkit-nsstring-substring.patch` | a Recaulk back-fill of `-[NSString containsString:]` |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/AWTView.m` | 2/2 | input-method check: same substitution | JDK-GUI | `patches-gui/0002-appkit-nsstring-substring.patch` | as above |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/AWTWindow.m` | 1/2 | full-size content view only where AppKit has it | JDK-GUI | `patches-gui/0003-appkit-window-tabbing-fullsize.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/AWTWindow.m` | 2/2 | skip `setAllowsAutomaticWindowTabbing:` (10.12+) where absent | JDK-GUI | `patches-gui/0003-appkit-window-tabbing-fullsize.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CDesktopPeer.m` | 1/3 | `legacyOpenURLs`: `NSWorkspaceOpenConfiguration` (10.15+) when available, else `LSOpenURLsWithRole` | JDK-headless | `patches/0006-desktop-launchservices.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CDesktopPeer.m` | 2/3 | `_lsOpenURI` calls `legacyOpenURLs` | JDK-headless | `patches/0006-desktop-launchservices.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CDesktopPeer.m` | 3/3 | `_lsOpenFile` calls `legacyOpenURLs` (print flag), `containsString:` → `rangeOfString:` with nil guards | JDK-headless | `patches/0006-desktop-launchservices.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CSystemColors.m` | 1/2 | `CONTROL_HIGHLIGHT`: `selectedContentBackgroundColor` only on 10.14+ | JDK-headless | `patches/0016-appkit-system-colors.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CSystemColors.m` | 2/2 | `CELL_HIGHLIGHT_COLOR`: `controlAccentColor` only on 10.14+ | JDK-headless | `patches/0016-appkit-system-colors.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CTrayIcon.h` | 1/1 | `AWTTrayIconView` subclasses `NSButton`, not `NSStatusBarButton` (10.10+) | JDK-GUI | `patches-gui/0005-appkit-tray-icon-nsbutton.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CTrayIcon.m` | 1/1 | borderless, image-only button | JDK-GUI | `patches-gui/0005-appkit-tray-icon-nsbutton.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/a11y/CommonComponentAccessibility.h` | 1/1 | superclass `NSObject <NSAccessibility>`, not `NSAccessibilityElement` (10.10+) | JDK-GUI | `patches-gui/0006-a11y-legacy-superclass.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/a11y/CommonComponentAccessibility.m` | 1/1 | `isAccessibilitySelectorAllowed:` no longer calls super | JDK-GUI | `patches-gui/0006-a11y-legacy-superclass.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/a11y/MenuAccessibility.m` | 1/1 | `NSAccessibilityMenuBarItemRole` only on 10.12+ | JDK-GUI | `patches-gui/0007-a11y-subrole-guards.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/a11y/TabButtonAccessibility.m` | 1/1 | `NSAccessibilityTabButtonSubrole` only on 10.13+ | JDK-GUI | `patches-gui/0007-a11y-subrole-guards.patch` | never |

Totals: 16 Recaulk, 22 JDK-headless, 10 JDK-GUI.

## Calls that could have gone either way

- **HotSpot clocks are Recaulk, not a JDK patch.** Hiker159's clock hunks substitute a private
  `clock_gettime` for the real one without changing which clock HotSpot asks for: timed waits,
  `javaTimeMillis` and `javaTimeNanos` keep `CLOCK_REALTIME`/`CLOCK_MONOTONIC`. The substitute exists only
  because 10.9 lacks `clock_gettime`, which Recaulk already provides (macports-legacy-support's, which
  also measures `CLOCK_MONOTONIC` with `mach_absolute_time`). So no JDK patch carries them.
- **`SecureDirectoryStream` is off on 10.9 (controller ruling R11).** The `*at` symbols come from
  Recaulk (macports-legacy-support 1.5.2), and most of them are directory-relative: they switch the
  calling thread's working directory to the descriptor (`__pthread_fchdir`). `renameat` is not, in
  the one case that matters: when the two descriptors differ and both names are relative
  (`atcalls.c`, `renameat`), it turns each descriptor into a path with `fcntl(F_GETPATH)` and calls
  `rename(path, path)`. `UnixSecureDirectoryStream.move` makes exactly that call
  (`renameat(this.dfd, from, that.dfd, to)`), so a parent of either side swapped for a symlink
  between `F_GETPATH` and `rename` redirects the move outside the directories the caller opened:
  a time-of-check/time-of-use race of the kind `SecureDirectoryStream` promises to exclude.
  Hiker159 kept it off by resolving `openat`/`fstatat`/`fdopendir` with `dlsym`, which with Recaulk
  linked would find Recaulk's and turn it back on, and which also turned it off on 10.10+. Our
  `patches/0007` instead asks libSystem itself (`dlopen` by path with `RTLD_NOLOAD`, then `dlsym`)
  for `renameat`: absent on 10.9, present from 10.10, so one binary keeps `SecureDirectoryStream`
  wherever the system's own `*at` calls exist.
- **UDP disconnect is a JDK patch, not a Recaulk `disconnectx`.** The JDK already has a BSD path and
  uses it on every other BSD; a generic `disconnectx` would have to answer for TCP and MPTCP as well.
  A Recaulk `disconnectx` is the exit.
- **`os.version` is a JDK patch.** `-[NSProcessInfo operatingSystemVersion]` is a Foundation method,
  not a C function, and Recaulk back-fills no Objective-C methods yet; the JDK already falls back to
  `SystemVersion.plist`. A Recaulk back-fill of the method is the exit.
- **Metal off in the build is headless; Java2D's choice of pipeline is GUI.** Upstream does not allow
  `--enable-headless-only` on macOS, so every macOS build compiles and links `libawt`, `libawt_lwawt`,
  `libsplashscreen` and `libosxui`; `libawt` (loaded headless, for images and fonts) links
  `Metal.framework`, which 10.9 does not have. Which pipeline Java2D picks at run time matters only
  once there is a window.
- **`Desktop` via LaunchServices is headless.** It lives in `libawt_lwawt`, but `Desktop.browse` and
  `Desktop.open` are what a command-line program uses to open a browser or a file, with no window of
  its own. Its `containsString:` substitutions stay with it, since they are in the same function.
- **Two of Hiker159's GUI patches ship in release 1; five stay parked.** With the four AppKit
  natives built against the 11.3 SDK (ruling R16), nothing in `patches-gui/` is needed to compile or
  link. `patches/0016` (was `patches-gui/0004`) moved because the compat guard refuses
  `libawt_lwawt` without it: `controlAccentColor` is on the guard's post-10.9 selector list.
  `patches/0015` (was `patches-gui/0001`) moved so that `-Djava.awt.headless=false` asks Java2D for
  OpenGL and fails clearly rather than reaching for Metal. The five still parked guard
  run-time-only AppKit and accessibility calls that a headless JDK never makes. The guard does not
  know their selectors, and their 10.10+ classes link weakly, so they would surface only on the 10.9
  box with a window.

## Rulings

Decisions made while porting, cited elsewhere in the repo as `R<n>` (`tests/rulings-test.sh` checks
that every cited one is defined here). Each says what was decided, why, and what it costs if wrong.

- **R10** Upstream configure refuses `--enable-headless-only` on macOS (`make/autoconf/jdk-options.m4`),
  so release 1 builds and links `java.desktop` in full. Patches needed to compile and link it against
  the 10.9 SDK live in `patches/`; `patches/0013` makes `java.awt.headless` default to true (still
  overridable). The release-2 gating commit deletes that patch rather than dropping a configure flag.
- **R11** `SecureDirectoryStream` stays off on 10.9: the only cross-directory `renameat` available goes
  through `F_GETPATH` and `rename()`, a race that breaks its guarantee. Callers fall back to the
  non-secure stream, which upstream already handles. Exit: Recaulk gains an fd-relative `renameat`.
- **R16** The four AWT natives (`libawt_lwawt`, `libosxui`, `libosxapp`, `libsplashscreen`) build
  against the pinned 11.3 SDK at minos 10.9, declared as `sdk-pin:` deviations; everything else uses
  the 10.9 SDK, and the compat guard still covers every Mach-O. Maintainer decision, 2026-11-05.
  Exit: the family's SDK-declaration facility widened to AppKit.
- **R17** C++ code compiled against clang22's libc++ headers links clang22's libc++, never the 10.9
  SDK's: mixing the two is the bug.
- **R18** No Rosetta anywhere, CI included: x86_64 code is never translated. It runs only on x86_64
  hardware, which in practice means the Mac OS X 10.9 box and the mavericks-vm guest (`vm-test`); no
  workflow uses an Intel runner. Scripts decide by the host's CPU, never by trying to execute
  (`tests/lib/host-cpu.sh`), so an arm64 runner that has Rosetta runs nothing of the image:
  build-jdk-test's runtime half skips there, and `tests/smoke-mavericks.sh` checks the installed JDK in
  the guest instead. `tests/rosetta-free-test.sh` keeps it so. Cost: nothing of the image runs on a
  modern arm64 Mac; its runtime checks wait for the guest.
- **R19** Man pages are generated with a pinned pandoc fetched into the build root (Renovate-tracked,
  never installed system-wide). Cost: a native 10.9 build cannot run that pandoc.
- **R20** No dSYMs (`--with-native-debug-symbols=none`): the image is about 180 MB smaller, as Apple's
  Java shipped none; crash logs still name exported symbols. Reversible by flag.
- **R21** R17 applies to every C++ binary (libjvm, libjsound, libfontmanager, the launchers): the
  family clang22 link route (`-nostdlib++`, `-load_hidden` clang22's `libc++.a`, `-lc++abi`),
  through the build's LDFLAGS. Cost: one hidden libc++ copy per C++ dylib.
- **R26** TCP urgent data from a peer must not busy-loop a `Selector` (servers are a target
  workload): `patches/0017` re-arms an urgent-only read so `select()` neither returns early nor spins.
- **R27** On Darwin before 17 (HFS+ only), `jdk.nio.path.useNormalizationFormD` defaults to true, so
  non-ASCII file names round-trip as they did on JDK 19 and earlier (`patches/0018`); an explicit
  `-D` still wins.
- **R28** The image ships no default CDS archive; the pkg's postinstall makes one with
  `bin/java -Xshare:dump`. A failed dump is logged and does not fail the install; on-target
  acceptance requires the archive.
- **R29** The build also makes the jtreg test natives (the native part of `make test-image`), and
  `tests/jtreg.sh` passes `-nativepath` when given them.
- **R30** UDP to a socket bound to one of the host's own non-loopback addresses, and multicast, are
  dropped on the multi-NIC 10.9 machine the gate was first run on (also from C and `nc`, so not the
  JDK); those tests are listed with that reason until they run on a single-NIC 10.9.
- **R31** `OutOfBand#id0` stays listed: its remaining case is a 10.9 kernel bug (normal data queued
  before an urgent mark is never reported readable by kqueue or poll; reproduced in C). R26's spin is
  fixed; a peer that mixes urgent and normal data can stall its own connection.
- **R33** ZGC is enabled: it builds against the 10.9 SDK unpatched, and jtreg `gc/z` and
  `tier1_gc_2` pass natively on 10.9.5.
- **R34** `lib/security/cacerts` is built from the family `ca-certs` product's trusted roots, pinned
  in `components/ca-certs/version`.
- **R35** `build-info.txt` records each SDK as `<dir>@sha256:<verified pin>`, not just its name.
- **R37** Hotspot's gtest suite is not built in release 1 (no `--with-gtest`); its six jtreg wrappers
  are listed. Cost: libjvm unit-level regressions on 10.9 go undetected until it is.
- **R38** `InheritedChannelTest` is listed under R30: its echo test sends UDP to `getLocalHost()`.
- **R39** The test natives include `test/lib`'s (`test-image-lib-native`, notably
  `libVThreadPinner`), which the virtual-thread pinning tests load.
- **R41** A `.jdk` is a bundle like `.app`: shipyard lists it once in the manifest's `outside`, and
  clears and removes it whole.
- **R44** 10.9's `java_home` and `/usr/bin` Java stubs see the `.jdk` only when it has both
  `Contents/MacOS/libjli.dylib` and `CFBundleExecutable`; with them, the stubs dispatch to this JDK
  and no system file is replaced. Cost: on install, a bare `java` means JDK 25 for every user, as
  Apple's Java chose the newest; `JAVA_VERSION` and `JAVA_HOME` still select others.
- **R45** The CDS tests fail against the unpacked image, which ships no archive (R28), and pass
  against the installed JDK. The gate runs against the installed JDK (R50), so they are not listed.
- **R46** The jdk pin moves on GA tags only (`-ga`, including CA respins): a Renovate bump that
  reaches main publishes, and jdk25u's newest build tags are early-access. The pins bot fills REF,
  DIGEST and TARBALL_SHA256 from the GA tag; until it does, the build refuses (fails closed).
- **R48** The jtreg pin follows the jdk source's own CI (`make/conf/github-actions.conf`); a mismatch
  fails the source job early.
- **R50** In the 10.9 guest, the jtreg gate runs `tests/jtreg.sh` with the pinned jtreg and the test
  natives against the installed JDK, one job per root, so each fits the job's time budget.
- **R51** The trademark legend appears verbatim in the pkg's `legal/`, as in the README and every
  release's notes.
- **R52** The upgrade leg of on-target acceptance installs the pinned previous release first; with
  none pinned yet, it says so and installs only this one.
- **R53** configure's autoconf is a pinned build input: GNU autoconf (`components/autoconf/version`)
  built on a pinned GNU m4 (`components/m4/version`), since autoconf needs m4 1.4.8 or later and
  `/usr/bin/m4` is 1.4.6 on 10.9 and modern macOS alike. Both are fetched with shipyard's
  `shipyard_fetch_pinned`, built with `/usr/bin/clang` and `/usr/bin/perl` into the build root, and
  handed to configure as `AUTOCONF`, so no host's own autoconf (pkgsrc's) decides the generated
  configure. Cost: about a minute on a build root's first build; a native 10.9 build needs
  `/usr/bin/clang` (the Command Line Tools), as `BUILD_CC` already does.
