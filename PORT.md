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
| `patches/0014-build-appkit-natives-sdk.patch` | the four AppKit natives build against `MAVERGREEN_APPKIT_SDK` (the 11.3 pin) at 10.9 (ruling R16) | the family SDK declaration facility widened to AppKit |
| `patches/0015-java2d-opengl-only.patch` | Java2D uses OpenGL, never Metal (was `patches-gui/0001`) | never |
| `patches/0016-appkit-system-colors.patch` | system colors without 10.14 selectors (was `patches-gui/0004`) | never |
| `patches/0017-nio-kqueue-selector-ignores-urgent-only-reads.patch` | the kqueue `Selector` ignores a read event that reports only urgent data while `SO_OOBINLINE` is off: it discards the byte and makes the socket's read filter `EV_CLEAR` until real data or EOF, so `select` neither selects the key, nor returns early, nor spins inside (ruling R26) | none while 10.9 is supported |
| `patches/0018-nio-normalize-paths-before-apfs.patch` | `jdk.nio.path.useNormalizationFormD` defaults to true before macOS 10.13 (HFS+ only); an explicit `-D` still decides (ruling R27) | none while 10.9 is supported |
| `patches/0019-build-tool-ldflags.patch` | native build tools (`TARGET_TYPE := BUILD`) add `MAVERGREEN_BUILD_TOOL_LDFLAGS` to their links when it is set, which `build/build-jdk.sh` does on 10.9 only (ruling R56) | upstream gives a native build's build tools their own extra LDFLAGS |
| `patches/0020-build-no-exploded-image-optimize.patch` | a native build no longer optimizes the exploded image, which a cross build never did, so its jmods' `module-info.class` are the cross build's bytes (ruling R59) | upstream's jmod writes the same bytes whether or not `ModulePackages` is already present |
| `patches/0021-java2d-metal-request-prints-opengl.patch` | `-Dsun.java2d.metal=true` prints one line on stderr saying it is ignored, then Java2D uses OpenGL as `0015` makes it; `tests/no-metal-test.sh` asserts no Mach-O links or needs Metal | never |

| `patches/0022-appkit-nsstring-substring.patch` | keyboard input's Keyman check uses `rangeOfString:`, not `containsString:` (10.10+) (was `patches-gui/0002`) | Recaulk back-fills `-[NSString containsString:]` |
| `patches/0023-appkit-window-tabbing-fullsize.patch` | full-size content view (10.10+) and automatic window tabbing (10.12+) only where `NSWindow` has them (was `patches-gui/0003`) | never |
| `patches/0024-appkit-tray-icon-nsbutton.patch` | the tray icon view is a borderless, image-only `NSButton`, not an `NSStatusBarButton` (was `patches-gui/0005`) | never |
| `patches/0025-a11y-legacy-superclass.patch` | `CommonComponentAccessibility` subclasses `NSObject <NSAccessibility>`, not `NSAccessibilityElement` (10.10+) (was `patches-gui/0006`; ruling R61) | never |
| `patches/0026-a11y-subrole-guards.patch` | menu-bar items and tab buttons report pre-10.12/10.13 roles (was `patches-gui/0007`) | never |

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
- **JDK-headless**: a JDK-specific change every build needs, GUI or not; the name is from release 1,
  which shipped headless. Carried in `patches/`, applied by shipyard's `apply_patches.sh`.
- **JDK-GUI**: AppKit, Java2D or accessibility. Carried in `patches/` too since release 2's GUI work
  landed on `main` (ruling R61); `patches-gui/` is gone.

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
| `src/java.desktop/macosx/native/libawt_lwawt/awt/AWTView.m` | 1/2 | `keyDown:`: `containsString:` (10.10+) → `rangeOfString:` | JDK-GUI | `patches/0022-appkit-nsstring-substring.patch` | a Recaulk back-fill of `-[NSString containsString:]` |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/AWTView.m` | 2/2 | input-method check: same substitution | JDK-GUI | `patches/0022-appkit-nsstring-substring.patch` | as above |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/AWTWindow.m` | 1/2 | full-size content view only where AppKit has it | JDK-GUI | `patches/0023-appkit-window-tabbing-fullsize.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/AWTWindow.m` | 2/2 | skip `setAllowsAutomaticWindowTabbing:` (10.12+) where absent | JDK-GUI | `patches/0023-appkit-window-tabbing-fullsize.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CDesktopPeer.m` | 1/3 | `legacyOpenURLs`: `NSWorkspaceOpenConfiguration` (10.15+) when available, else `LSOpenURLsWithRole` | JDK-headless | `patches/0006-desktop-launchservices.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CDesktopPeer.m` | 2/3 | `_lsOpenURI` calls `legacyOpenURLs` | JDK-headless | `patches/0006-desktop-launchservices.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CDesktopPeer.m` | 3/3 | `_lsOpenFile` calls `legacyOpenURLs` (print flag), `containsString:` → `rangeOfString:` with nil guards | JDK-headless | `patches/0006-desktop-launchservices.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CSystemColors.m` | 1/2 | `CONTROL_HIGHLIGHT`: `selectedContentBackgroundColor` only on 10.14+ | JDK-headless | `patches/0016-appkit-system-colors.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CSystemColors.m` | 2/2 | `CELL_HIGHLIGHT_COLOR`: `controlAccentColor` only on 10.14+ | JDK-headless | `patches/0016-appkit-system-colors.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CTrayIcon.h` | 1/1 | `AWTTrayIconView` subclasses `NSButton`, not `NSStatusBarButton` (10.10+) | JDK-GUI | `patches/0024-appkit-tray-icon-nsbutton.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/CTrayIcon.m` | 1/1 | borderless, image-only button | JDK-GUI | `patches/0024-appkit-tray-icon-nsbutton.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/a11y/CommonComponentAccessibility.h` | 1/1 | superclass `NSObject <NSAccessibility>`, not `NSAccessibilityElement` (10.10+) | JDK-GUI | `patches/0025-a11y-legacy-superclass.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/a11y/CommonComponentAccessibility.m` | 1/1 | `isAccessibilitySelectorAllowed:` no longer calls super | JDK-GUI | `patches/0025-a11y-legacy-superclass.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/a11y/MenuAccessibility.m` | 1/1 | `NSAccessibilityMenuBarItemRole` only on 10.12+ | JDK-GUI | `patches/0026-a11y-subrole-guards.patch` | never |
| `src/java.desktop/macosx/native/libawt_lwawt/awt/a11y/TabButtonAccessibility.m` | 1/1 | `NSAccessibilityTabButtonSubrole` only on 10.13+ | JDK-GUI | `patches/0026-a11y-subrole-guards.patch` | never |

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
- **Two of Hiker159's GUI patches shipped in release 1; the other five followed (ruling R61).** With the four AppKit
  natives built against the 11.3 SDK (ruling R16), nothing in `patches-gui/` is needed to compile or
  link. `patches/0016` (was `patches-gui/0004`) moved because the compat guard refuses
  `libawt_lwawt` without it: `controlAccentColor` is on the guard's post-10.9 selector list.
  `patches/0015` (was `patches-gui/0001`) moved so that `-Djava.awt.headless=false` asks Java2D for
  OpenGL and fails clearly rather than reaching for Metal. The other five, parked until release 2,
  guard run-time-only AppKit and accessibility calls that a headless JDK never makes. The guard does
  not know their selectors, and their 10.10+ classes link weakly, so they would surface only on the
  10.9 box with a window; they are `patches/0022`-`0026` now.

## Rulings

Decisions made while porting, cited elsewhere in the repo as `R<n>` (`tests/rulings-test.sh` checks
that every cited one is defined here). Each says what was decided, why, and what it costs if wrong.

- **R10** Upstream configure refuses `--enable-headless-only` on macOS (`make/autoconf/jdk-options.m4`),
  so release 1 builds and links `java.desktop` in full. Patches needed to compile and link it against
  the 10.9 SDK live in `patches/`; `patches/0013` made `java.awt.headless` default to true (still
  overridable). The GUI release (25.0.5.0.3-mavericks.3) deleted that patch, in Task 20's gating
  commit, rather than dropping a configure flag. Since then upstream's default holds: headless
  exactly when the process is outside an Aqua session (`PlatformGraphicsInfo.getDefaultHeadlessProperty`).
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
  JDK). Its exit is met: they pass on a single-NIC 10.9 in the mavericks-vm guest, so they live in
  `tests/known-failures/x86_64-10.9-multihomed-host.txt` (R54), not the release gate's list.
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
- **R54** The guest's jtreg gate is the release gate, so `tests/known-failures/x86_64-10.9.txt` lists
  only what fails on a clean single-NIC 10.9, which the guest is. What fails only because of one host
  (the multi-homed box's network: the R30 lines, a host name with two addresses, a slow resolver)
  lives in that host's overlay, `tests/known-failures/x86_64-10.9-multihomed-host.txt`, which
  `tests/jtreg.sh` reads after the main list (`tests/jtreg.sh JDK tests/known-failures/x86_64-10.9.txt
  tests/known-failures/x86_64-10.9-multihomed-host.txt`), so the release gate is not blind to them.
  Cost: a native gate on that box must pass the overlay too.
- **R55** A native 10.9 build is checked against the cross build by `build/compare-builds.sh`. Every
  file and every jmod, jar and zip entry must be in both images with the same bytes, except Mach-O,
  whose bytes may differ and are reported. An archive is compared by its entries, never its own bytes,
  since configure's default `--with-source-date=current` stamps them with its own time. When a Mach-O
  differs, only what records its hashes may differ with it, each reported as excused: `lib/modules`,
  and a jmod's `classes/module-info.class` that holds `ModuleHashes` on both sides (in 25.0.5,
  `java.base`'s alone). It also excuses, and names, what differs by design: the `host` each was built
  on; the `bootjdk` (10.9 boots with the installed jdk25, since the pinned Temurin build is aarch64;
  the cross build with that Temurin); and, when one side records `pandoc=none`, the man pages it could
  not make (R19), in the image's `man/` and each jmod's `man/`. Both builds configure with
  `--disable-cds-archive`: the image ships no default CDS archive and the postinstall writes it (R28),
  and a cross build cannot make one while a native one would. An archive inside a jmod
  (`jdk.compiler`'s `lib/ct.sym`) is compared by its entries too. A jar manifest's `Created-By` line
  is compared apart from the rest of the manifest and excused only when `bootjdk` differs: the jar
  tool writes it from the JDK that runs it, the boot JDK (`25.0.5 (Eclipse Adoptium)` against
  `25.0.5.0.3 (Mavergreen)`). Cost: the native build's man pages go unchecked, a class differing only
  inside `lib/modules` is caught through its jmod, not there, and the manifests do not show which
  JDK built the image.
- **R56** R21's link route reaches the native build's build tools too. A native 10.9 build is not
  cross-compiling, so configure builds hotspot's adlc with the target's clang22 and its libc++
  headers (`BUILD_CXX` is `CXX`) but links it with none of `--with-extra-ldflags`, and adlc takes no
  default LDFLAGS either; it then linked the 10.9 SDK's libc++ (`std::__1::__hash_memory` undefined).
  `build/toolchain.sh`'s `jdk_link_flags` is the one route (Recaulk, clang22's `libc++.a` hidden,
  `libc++abi`, `-dead_strip_dylibs`), given to the image's links by `--with-extra-ldflags` and, on
  10.9 only, to every build tool's link by `patches/0019`'s `MAVERGREEN_BUILD_TOOL_LDFLAGS`. Not a
  make command-line `BUILD_LDCXX`: on the build host it did not reach adlc's link, under
  `/usr/bin/make` (GNU Make 3.81, 10.9's) or pkgsrc's make, while an environment variable reaches
  every sub-make. Not a flag on `CXX`: the image's C++ links already take the route, and taking
  it twice changes their bytes. The cross build leaves the variable unset, so its build tools, arm64
  host tools built with `/usr/bin/clang++`, are unchanged. Cost: one more patch, to OpenJDK's
  `make/common/NativeCompilation.gmk`.
- **R57** A native 10.9 build signs every Mach-O as the cross build does (configure's debug mode:
  `codesign -f -s - --entitlements …`), through `jdk_codesign_shim`, which `build/build-jdk.sh` hands
  configure as `CODESIGN` on 10.9 only. Before signing, OpenJDK's `make/common/native/Link.gmk` runs
  `codesign --remove-signature` on each binary only to avoid a warning, and 10.9's codesign refuses
  that on every thin x86_64 binary ("unsupported type or version of signature"); the shim takes that
  one call as a no-op, and `-f` replaces whatever signature the linker left. Not
  `--with-macosx-codesign=disabled`: the native image would then carry no signature or entitlements
  where the cross image does. The cross build passes no `CODESIGN`. A signature is Mach-O bytes, which
  `build/compare-builds.sh` already lets differ (R55). Cost: 10.9's codesign writes an older
  CodeDirectory (v=20100) than the runner's (v=20400). Exit: OpenJDK drops the removal step, or the
  family gains a codesign that 10.9 builds use.
  The shim also leaves unsigned, saying so on stderr, an unsigned Mach-O whose segment at file
  offset 0 has no sections. lld writes one when `-dead_strip` leaves a link no code (the jtreg native
  `libHasNoEntryPoint`, whose one function is hidden), and 10.9's `codesign_allocate` (cctools-862,
  `misc/codesign_allocate.c` `add_code_sig_load_command`) then takes that segment's offset, 0, as
  where the first section starts and refuses to add `LC_CODE_SIGNATURE` ("larger updated load
  commands do not fit"); later cctools skip a segment at offset 0. No `-headerpad` helps. Such a file
  has no code to sign, and release 1's image holds none. Not a section added to every native link:
  that would change every native Mach-O, where this changes only the files 10.9 cannot sign. Exit:
  the same, or lld keeps an empty `__text`.
- **R58** `build/build-jdk.sh` builds with `TZ=UTC`. `lib/classlist` lists the classes
  `HelloClasslist` loads, and it formats a date in the default time zone; a zone with transitions
  also loads `sun.util.calendar.ZoneInfoFile$Checksum`, so a build in New York listed one class more
  than CI's, whose runners are in UTC. Upstream already pins the locale for the same reason. Not
  excused in `build/compare-builds.sh`: the classlist is what the CDS archive the postinstall writes
  (R28) starts from, so it should not depend on where the build ran. CI's runners already run in UTC
  (release 1's classlist has no such line), so its builds are unchanged.
  `tests/build-jdk-test.sh` refuses an image whose classlist lists that class.
- **R59** A native build makes its jmods as a cross build does: `patches/0020` drops upstream's
  `exploded-image-optimize` from a non-cross build. That step adds `ModulePackages` to each exploded
  `module-info.class` before `jmod create` extends it, and jmod's `ModuleInfoExtender` then orders
  the constant pool differently (`ModulePackages` before the module version), so each jmod's
  `module-info.class` differed from the cross build's in constant pool order alone, with the same
  content by `javap -v` (reproduced on the arm64 host by running `AddPackagesAttribute` before
  `jmod create`). Not a class file comparison in `build/compare-builds.sh`: fixing the source keeps
  the comparison to bytes and needs no JDK to compare with. The cross build never ran that step and
  is unchanged. Cost: the native build's exploded image, which it runs jmod and jlink from, starts a
  little slower. Exit: jmod writes the same bytes whether or not `ModulePackages` is present.
- **R60** `tests/smoke-mavericks.sh` asserts R44 end to end on 10.9 through `tests/smoke-usr-bin.sh`,
  with `JAVA_HOME` and `JAVA_VERSION` unset. It checks that:
  - `java_home -V` lists "Mavericks JDK 25";
  - `/usr/bin/java`, `javac` and `jar` report our version and compile, jar and run a Main-Class jar;
  - `$(java_home -v 25)/bin/jshell` evaluates `6*7` (Apple never shipped `/usr/bin/jshell`, and we
    add nothing to `/usr/bin`);
  - `JAVA_HOME=$(java_home -v 25) /usr/bin/java` reports our version;
  - `open -a "Jar Launcher"` on that jar writes its marker;
  - no stub printed Apple's "No Java runtime present, requesting install.";
  - no new `Java Updater.app` or `Install*.app` executable appeared (`ps -o comm=`, compared before and
    after), so PackageKit's ever-running `installd`, and process arguments, never count.

  `open -a` reaches LaunchServices only from this user's GUI login. Where `/dev/console` belongs to
  anyone else, the Jar Launcher check prints "skipped: no window server" and the rest still runs.

  The script takes stand-in paths, so `tests/smoke-usr-bin-test.sh` runs it off 10.9 against the boot
  JDK, one broken input per case. Only 10.9 proves Apple's stubs, the installer's real process name
  and Jar Launcher.

  Cost: the mavericks-vm guest boots to the login window with no one logged in. packer-plugin-macosx's
  default build sets no password, so it has no auto-login (its `docs/configuration-register.md`,
  "auto-login"), and there the check always skips. Only the box proves Jar Launcher. Exit: the guest is
  built with a password and auto-login, and then the skip never prints there.
- **R61** Release 2's AppKit/Foundation sweep (Task 16) found nothing past Hiker159's five parked GUI
  patches, which moved from `patches-gui/` to `patches/0022`-`0026` on `main`, applied headless or not.
  The sweep, on a `gui` build with them applied:
  - every compile of the AppKit natives (libawt_lwawt, libosxapp, libosxui, libsplashscreen, libawt,
    libjawt, libfontmanager) rerun with `-Wunguarded-availability` (off by default; clang warns only
    about 10.13+ APIs without it): 80 warnings, each a send to one of our own classes that defines the
    method, an enum constant, or already behind `respondsToSelector:` or `@available`;
  - every Objective-C class those libraries import, against the 10.9 SDK's AppKit, Foundation and
    QuartzCore: only `NSAccessibilityElement` (`0025` removes it) and `NSWorkspaceOpenConfiguration`
    (behind `@available(macOS 10.15, *)`, `patches/0006`);
  - the compat guard, selectors included, which passed before and after.

  Cost: the accessibility classes implement the 10.10 `NSAccessibility` protocol (`accessibilityRole`
  and the rest), and 10.9's AppKit asks the informal protocol (`accessibilityAttributeValue:`)
  instead, and nothing on 10.9 bridges the two. Nothing crashes, but VoiceOver on 10.9 cannot reach
  a Swing component.

  Measured (Task 18), the maintainer's VoiceOver pass on 10.9.5, 2026-11-08, against the gui image
  cdad3e6 in GuiSmoke's hold mode (`SMOKE_GUI_HOLD=1`). The verdict is **partial**:

  | Row | Control | Heard |
  |---|---|---|
  | 1 | Smoke menu, in the screen's menu bar (AppKit's own `NSMenu`) | "Smoke menu, one item", then "say hello" |
  | 2 | "Your name:" text field (Swing) | unreachable |
  | 3 | "Say hello" button (Swing) | unreachable |
  | 4 | the label the button sets (Swing) | unreachable |
  | 5 | the window | "GuiSmoke VoiceOver window", and its title-bar buttons |

  Ctrl-Option-Right cycles only the title-bar controls. The VoiceOver cursor never enters the
  content, and it does not follow keyboard focus: it stayed on the close button while focus was in
  the text field. Tab still moves keyboard focus visibly. The gap is declared on `gui` as
  `on-target:accessibility` (ruling R65).

  Exit: an informal-protocol bridge in `CommonComponentAccessibility` that makes VoiceOver read
  GuiSmoke's hold-mode controls (QUEUE "jdk25: Swing is invisible to VoiceOver on 10.9").
- **R62** `tests/java/GuiSmoke.java` judges its first `Robot.getPixelColor` read-back by which channel
  dominates, not against the sRGB it painted. Robot reads the display's colour space: on the 10.9 box,
  sRGB `#219e5b` read back as `#009d5b`, red 33 off. So:
  - the first read must show green over red by 60 and over blue by 30;
  - a repaint with red and green swapped must then read red over the others the same way;
  - green again, and every later read (after the resize, in full screen), must come within 12 per
    channel of that first read.

  A display profile keeps the dominant channel of a saturated colour, so this works on any profile. A
  black, unpainted (window grey) or wrongly coloured panel still fails. Converting the sRGB colour
  through the screen's colour space was not done: Java exposes no display ICC profile on macOS.

  `screenmenubar` sets `apple.laf.useScreenMenuBar=true` and asserts through public API that Aqua gave
  the frame its `com.apple.laf.ScreenMenuBar`, the AWT `MenuBar` AppKit shows as the screen's menu bar,
  holding the one menu, and that the `JMenuBar` takes no height in the window. That proves the hand-off
  to AppKit, not the pixels. `SMOKE_GUI_SHOTS` saves `screenmenubar.png` to check those by eye.

  `tests/smoke-gui.sh` skips with 77 on a locked screen or an asleep display, as `ioreg` reports them
  (`IOConsoleUsers`' `CGSSessionScreenIsLocked`, `IODisplayWrangler`'s `CurrentPowerState`): Robot reads
  black there while the console is still this user's. Where a key is absent, the pixel `FAIL` names
  both causes and ssh, from which 10.9 gives screen capture nothing.

  Cost: a colour that keeps its dominant channel but is otherwise wrong passes the first read. Exit:
  a supported way to read the display's profile, then compare in that space.
- **R63** GuiSmoke's `print` step prints through `PrinterJob` to a PostScript file, by a
  `StreamPrintService`, and not to PDF.
  - **Why not PDF:** macOS's `CPrinterJob` sends a job to a file (`NSPrintSaveJob`, PDF) only when its
    own print dialog chose one: `setDestinationFile` sets `destinationAttr`, the only destination its
    native print loop reads. A `Destination` attribute given to `print(attributes)` reaches
    `RasterPrinterJob`'s `mDestination` and goes no further. So a dialog-free "print to PDF file"
    through public API prints on the default printer instead.
  - **Why PostScript is safe:** `CPrinterJob.print` returns through `spoolToService` for a
    `StreamPrintService` before it touches the native path, so no queue or dialog is reachable. The
    step also refuses to print unless the job's service is that stream.

  Cost: the step proves `PrinterJob` and Java2D's print graphics, not AppKit's print path. On 10.9 a
  user makes a PDF through the native print dialog's PDF button. Task 19's real-hardware pass checked
  that by hand on 2026-11-08: a probe calling `PrinterJob.printDialog()` showed the native macOS
  dialog, and PDF > Save as PDF wrote the page. The same pass found that Java's cross-platform dialog
  (`JTable.print` uses it) offers Print To File, which by this ruling's reading reaches the real
  printer. The maintainer cancelled it rather than try. The release notes warn of it, and the
  controller's QUEUE tracks it. No untested `CPrinterJob` patch (the controller's ruling, 2026-11-07): a
  wrong one prints on a real printer. Exit: a patch that makes `CPrinterJob` honour a `Destination`
  attribute, tested where no printer queue exists, if the maintainer wants that path automated.
- **R64** GuiSmoke never calls `Desktop.browse` unless asked (`SMOKE_GUI_BROWSE=1`), the controller's
  ruling of 2026-11-07. `CDesktopPeer`'s browse sends any URI to the default browser:
  `URLForApplicationToOpenURL:` on `https:`, then that app opens it. On the 10.9 box that's a running
  Firefox fork, so a `file:` folder URL went to the maintainer's browser, not Finder. By default the
  step requires only that `BROWSE` is supported, and says that Java has no public API naming the
  default browser. `Desktop.open` still opens a temporary folder in Finder and closes it.

  Cost: browse's LaunchServices path runs only in the opt-in run, which browses a small `file:` page
  and asks for an eye check: Task 19's hands-on pass. Exit: none needed; a smoke must not drive the
  maintainer's own browser.
- **R65** The `on-target:accessibility` deviation (Swing invisible to VoiceOver on 10.9, R61) was
  declared on `gui`, beside the flag flip, not on `main`. Until the GUI release, `main`'s JDK was
  headless by default (`patches/0013`), so no Swing window reached AppKit, and `on-target:gui`
  declared GUI unsupported. The gap reaches users only in the release that turns the GUI on. Task
  20's gating commit deleted `on-target:gui`; this line stays until its exit.

  Cost: before the GUI release, `main`'s `INGREDIENTS.md` didn't list the gap. Exit: as R61's.
- **R66** The 10.9 close race is fixed in Recaulk (20261109.1, from its main at 3c30f56, and later),
  not in a jdk-25 patch: the maintainer's ruling that portability fixes live in Recaulk. libnio's
  `close` and `dup2`, and libnet's `close`, bind to Recaulk's. `jdk_link_flags` passes the pinned
  `librecaulk.a` first, and clang22's bundled, older Recaulk defines neither symbol. A test link
  with those flags defines `_close`, `_close$NOCANCEL` and `_dup2` from `___recaulk_close` and
  `___recaulk_dup2`, and imports neither from libSystem.
  - **The cause, the XNU drain race:** in xnu-2422 (10.9), `dup2` or `close` on a busy descriptor
    drains it. `fileproc_drain` calls `soo_drain`, which sets `SS_DRAINING` and wakes sleepers,
    then sleeps with no timeout. `sbwait` (read, receive) and `accept` check `SS_DRAINING` only
    after their own `msleep`. A thread that has taken the descriptor but not yet slept misses that
    wakeup and sleeps. The drain then waits until some unrelated descriptor in the process drops
    to no users (`fp_drop`). JDK 25 pre-closes with `dup2` and signals blocked threads only after it
    returns. So `java/net/Socket/asyncClose/Race.java` hung the mavericks.3 release's guest run
    past 480 s, and the 10.9 box's stall probe found `main` in `UnixDispatcher.preClose0`'s `dup2`
    and one reader in `read()` in all 58 stalls of 100 runs.
  - **Which macOS has it:** xnu-3789 (10.12) checks `SS_DRAINING` in `sbwait` before sleeping, and
    xnu-2782 (10.10) does not. `accept` lacks the check even in xnu-7195 (macOS 11), where
    `fileproc_drain` still has no timeout. On an arm64 Mac running current macOS, stock JDK 25
    stalled AcceptCloseRace past 3 s in 2 of 8 runs.
  - **Evidence on 10.9.5:**

    | | mavericks.2 | JDK built from `fcd4c70` with Recaulk's close-race fix |
    |---|---|---|
    | CloseRace (`read`), 3000 | FAIL at iteration 1130 | clean, slowest close 4 ms |
    | AcceptCloseRace, 3000 | FAIL at iteration 1292 | clean |
    | UdpCloseRace, 3000 | FAIL at iteration 2075 | clean |
    | race-probe (Race.java) | 58 stalls in 100 runs | 150 runs, 0 stalls |

    The probes are in `mm-transfer/race-hang/probe`. A jdk-25 patch was tried first and dropped.
    Shutting the socket down before `dup2` fixed `read` only: `soshutdown` returns `ENOTCONN` for
    a listening or unconnected socket, and AcceptCloseRace and UdpCloseRace still failed.
  - **Guarded by** LegacySmoke's required steps `closeRace`, `acceptCloseRace` and `udpCloseRace`.
    Each makes 5000 closes against a thread entering `read()`, `accept()` or `receive()`, and fails,
    naming the iteration, while a close is still blocked after 3 s or a blocked thread has not
    finished 3 s after its close. A stuck close waits for unrelated descriptor activity, which the
    loop has none of, so 3 s catches it as surely as 500 ms would, and leaves a slow guest room.
    `tests/legacysmoke-closerace-test.sh` proves the failure paths with held calls. It leaves
    `acceptCloseRace` to the 10.9 runs, because current macOS keeps the `accept` race.
  - **Race.java** left the known-failures list: the guest gate runs it again.

  Cost: none in jdk-25. The fix and its costs are Recaulk's. Exit: none while 10.9 is supported.
