# Main-thread filesystem hang in 0.10.0

Baseline: `7ded39e8b62a8c4535669c92ca4fef560167f3a1`. Changes are uncommitted in this worktree. No install, live app restart, live device write, Dock/Menu Bar preference write, commit, push or release was performed.

## Root cause

The interim-3302 report and `app-hang-3s-sample.txt` show 2,516 main-thread samples in the same stack. `DockEnhance.swift:987` mapped every cached Dock tile through `bundleID(forTile:)`. At baseline line 1012, that method called `Bundle(url:)?.bundleIdentifier`. The app-only filter ran afterward. A directory tile therefore reached `NSBundle.infoDictionary`, `CFBundleCreate`, `_CFIterateDirectory`, `__opendir2` and a blocked `open` on the main thread.

The captured Dock preferences include a Downloads directory tile. Downloads is a candidate for the pending open, not a proven syscall path. The sample proves the synchronous bundle lookup caused the main-thread wait; it does not prove which permission dialog or filesystem condition held that open.

The quick-quit mirror now filters app tiles before resolving identifiers. Running-app identifiers come from the existing workspace index. Other bundle reads run through the background cache.

## Execution and access policy

[BackgroundLookupCache.swift](../../app/Sources/JRBarApp/BackgroundLookupCache.swift) returns a cached value or placeholder immediately. The loader runs on a utility Dispatch queue. Each cache limits active reads, normally to two, expires results after 30 seconds, and gives a read a two-second deadline. Late results are discarded. A timed-out syscall keeps its worker slot until it returns, so repeated UI reads cannot spawn unlimited blocked workers. Async callers can wait for a slot or result without occupying the main thread.

[ExternalFileMetadata.swift](../../app/Sources/JRBarApp/ExternalFileMetadata.swift) separates file facts, icons and requested attachments. The worker preserves the running app, declared bundle icon, and workspace fallback chain. Icons are decoded before publication. Attachments have one worker and two cache entries, and are loaded only on request. Clipboard image upgrades check that the clipboard has not changed since the reference was copied.

Automatic probes reject Desktop, Documents, Downloads, cloud-storage paths, user-library paths other than Sounds, `/Volumes` and `/Network` before filesystem inspection. The Shelf authorizes an exact item. It does not authorize its parent, siblings or descendants. Removing and re-adding an item creates a new cache grant. Component inspection rejects symlinks, dataless items and nonlocal filesystems before content loading. No download API is called.

## Main-thread calls moved or removed

Locations below refer to the changed source. Function names identify each call site.

- [DockEnhance.swift](../../app/Sources/JRBarApp/Utilities/Dock/DockEnhance.swift): `mirrorQuickQuitTargets` and `bundleID(forTile:)` use the cache and running-app index. `resolveTile`, `quickQuit(axPoint:force:)`, scroll-down handling and `minimizeFrontWindows` no longer call `Bundle(url:)`. `DockTileApp.init` obtains a cached icon instead of reading `NSRunningApplication.icon`. `openDocumentInPreview` no longer checks file existence before handing off a document.
- [DockSwitcher.swift](../../app/Sources/JRBarApp/Utilities/Dock/DockSwitcher.swift): window-list assembly, windowless-app assembly and app-strip assembly replace running-app icon reads with cached icons.
- [DockIconResolver.swift](../../app/Sources/JRBarApp/Utilities/Dock/DockIconResolver.swift): preview icon resolution no longer opens a bundle or calls `icon(forFile:)` on the main thread. Rasterization reads decoded cached images.
- [DockPreviewSample.swift](../../app/Sources/JRBarApp/Utilities/Dock/DockPreviewSample.swift): sample file and application icons use the cache. The Ghostty existence check uses LaunchServices registration.
- [ExternalAppProbe.swift](../../app/Sources/JRBarApp/Utilities/ExternalAppProbe.swift): `ApplicationsFolderIndex.entries` no longer enumerates `/Applications` while holding its caller's lock. Enumeration runs in the bounded cache.
- [ShelfTray.swift](../../app/Sources/JRBarApp/ShelfTray.swift): load/show revalidation and relocation no longer synchronously test file existence or directory attributes. `icon(for:)`, `size(of:)`, attachment bounds and clipboard image loading use cached or asynchronously prepared values. Quick Look request construction and file checks run off the main thread. Missing-state updates arrive through observation.
- [ShelfDragSource.swift](../../app/Sources/JRBarApp/ShelfDragSource.swift): drag-image construction uses a cached icon or generic file icon.
- [NotchCardView.swift](../../app/Sources/JRBarApp/Toys/Notch/NotchCardView.swift): Shelf drag references use the item's cached missing state. Files handed to a session request attachment preparation asynchronously.
- [PaletteView.swift](../../app/Sources/JRBarApp/Palette/PaletteView.swift): `PaletteAppIcons.icon` replaces running-app and file-icon reads with cached icons.
- [MenuBarBar.swift](../../app/Sources/JRBarApp/Utilities/MenuBar/MenuBarBar.swift): `MenuBarAppIcons.icon` replaces running-app and file-icon reads with cached icons.
- [ShelfUtility.swift](../../app/Sources/JRBarApp/ShelfUtility.swift) and [NotchControlsView.swift](../../app/Sources/JRBarApp/Toys/NotchControlsView.swift): player and application names use LaunchServices URLs and their names, without `FileManager.displayName`.
- [NotchToy.swift](../../app/Sources/JRBarApp/Toys/NotchToy.swift) and [FoldToy.swift](../../app/Sources/JRBarApp/Toys/Fold/FoldToy.swift): boring.notch and Bendy bundle-identifier probes use cached metadata.
- [FileWatcher.swift](../../app/Sources/JRBarApp/FileWatcher.swift): vnode-watch opens run through a bounded background cache. Late or canceled opens close their descriptors off the main thread. `start` schedules an open; `isActive` becomes true when it lands.
- [AppDelegate.swift](../../app/Sources/JRBarApp/AppDelegate.swift): socket-watcher setup no longer performs a synchronous existence preflight.
- [SettingsPagesShell.swift](../../app/Sources/JRBarApp/SettingsPagesShell.swift): sound-directory inventory and command-line-tool status run in background caches. Explicit command-line-tool installation and removal run detached.
- [SettingsStore.swift](../../app/Sources/JRBarApp/SettingsStore.swift): selected settings imports have a background read deadline. Exports write off the main thread. Revealing the state directory no longer performs an existence preflight.
- [SparkleUpdater.swift](../../app/Sources/JRBarApp/SparkleUpdater.swift): stale-copy filtering compares standardized paths without filesystem symlink resolution.
- [NotchAnnouncements.swift](../../app/Sources/JRBarApp/NotchAnnouncements.swift): Focus announcements use the existing daemon feed. The direct protected-database read and directory open are removed. Tink lookup and preparation run in a background cache; the network sounds directory is no longer probed.
- [SetupModel.swift](../../app/Sources/JRBarApp/Setup/SetupModel.swift): the Full Disk Access row reports unknown instead of reading the protected Focus database.
- [SoundPlayer.swift](../../app/Sources/JRBarApp/SoundPlayer.swift): named-sound existence checks, inventory, file reads and alert-file preparation run in background caches. Current-output players consume prepared bytes. Synthesized files remain in JR-Bar's own cache.
- [LEDFeed.swift](../../app/Sources/JRBarApp/LEDFeed.swift): the remaining main-actor file-existence check now runs beside the existing background program and modification-time reads.
- [AlcoveMediaAdapter.swift](../../app/Sources/JRBarApp/Toys/Notch/AlcoveMediaAdapter.swift): the `/usr/bin/perl` executable preflight is removed. Process launch reports a missing executable through its existing error path.
- [AquariumSun.swift](../../app/Sources/JRBarApp/Toys/Aquarium/AquariumSun.swift): the system timezone table loads through a background cache. Fixed hours remain the initial fallback.

## Existing background readers hardened

- `DockEnhance.folderListing` checks access before opening a folder and rejects unavailable entries before sorting or loading icons. A protected Dock folder shows unavailable content rather than probing for permission.
- `DockInstalledApps.scan` checks paths before enumeration and bundle reads. Its caller now has a cache and deadline.
- `FoldWallpaperSource.frame` checks access and availability before decoding and has a deadline.
- `OverviewStore` checks workspace access. `GitWorkspace.resolve` also checks `.git`, redirected worktree HEAD files and `commondir` before reading them.
- `ShelfActions.text` and image conversion reject unavailable source files before content reads.

The audit found no separate recent-document filesystem reader in `app/Sources`. Palette and session history consume existing models. JR-Bar's state, save files, generated clips, helper files, glyph cache, setup state and explicitly isolated preview state remain its own storage. Existing device reads and explicit Shelf operations already run off the main thread; no device writes were added or exercised.

## Verification

`env -u JRBAR_INTERACTIVE_TESTS swift test --no-parallel` passed all four targets:

- 116 LEDS tests.
- 67 UI tests.
- 1,394 Core tests.
- 4,500 App tests.
- Total: 6,077 tests.

Eight new regression tests in the final full run cover a blocked Dock bundle lookup, folder filtering before resolution, worker-slot retention after timeout, protected paths submitting no reads, dataless/symlink/network component rejection, retirement of a Shelf grant, the declared icon of an unregistered synthetic app, and the unavailable state for policy-blocked folders. Tests release blocked workers before returning. Existing Shelf tests now wait for metadata updates before asserting filesystem-derived state.

`PYTHONPATH="$PWD/src" /Users/jonathanreed/Downloads/JR-Bar/.venv/bin/python -m pytest tests -q` passed: 15,866 tests and 15 subtests, with four warnings. No Python source was changed.

`git diff --check` passes. Swift source and test changes are bound by this manifest SHA-256: `c4ed5c2e0bcc2d2e2be85abd6fa24e17f5c6bfb1971dad5a3c6df67d597ed4f9`. The manifest hashes each changed Swift path, a NUL, its bytes, and a NUL, in sorted path order, including the three new Swift files.

Swift log: `/tmp/jrbar-swift-final.log`. Python log: `/tmp/jrbar-python-full.log`.

The installed hung app was not restarted or replaced. These are source, build and injected-test results. They do not establish a fixed installed build, a completed visual walkthrough, or an OS-level TCC acceptance pass. No new PNG proof was produced.
