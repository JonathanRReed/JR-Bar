import AppKit
import JRBarCore
import OSLog

/// The macOS 27 hiding mechanism (docs/AUDIT-2026-09-16.md): the menu
/// bar is one surface `MenuBarAgent` draws, and the only thing that
/// truly removes another app's item from it is the agent's own
/// *assessment mode* — the exam-lockdown feature — driven through the
/// private `MenuBarClientCore` framework. An assertion carries an
/// allowlist of system items and bundle identifiers; the agent conceals
/// every other application's items itself. No spacer, no blank
/// stretch, no «, nothing of ours drawn.
///
/// The API surface is resolved at runtime (`dlopen` + class lookup +
/// selector checks) and every call fails soft: when a point release
/// changes it, `isAvailable` turns false and the spacer engine stands
/// in. Facts about the mechanism, measured on 27.0 by Ice (PR #995) and
/// Pelmet and confirmed here: only a signed app bundle's allowlist is
/// honoured; live assertions combine as a union of allowlists, so a
/// change activates the new assertion *before* invalidating the old and
/// an app concealed on both sides never flickers; the agent ignores
/// clicks on its own clock, battery and Wi-Fi while any assertion is
/// live (Control Center still opens) — `MenuBarSystemClickBridge` lifts
/// concealment for the click and replays it; concealed items leave the
/// Accessibility tree or report stale frames, so what is hidden is
/// tracked per application, never inferred from a frame; and the agent
/// reorders items on its own, so a section is a per-application setting
/// (`MenuBarSettings.concealedApps`), not a bar position.

// MARK: - Pure planning

enum MenuBarConcealPlan {
    /// Apple extras use per-item covers, matching the visibility picker.
    /// Do not also put them in the app-level assessment map.
    nonisolated static func canConcealApp(_ bundleID: String) -> Bool {
        !bundleID.hasPrefix("com.apple.")
    }

    /// The applications an assertion must conceal for a reveal state:
    /// the hidden apps unless the hidden run is revealed, the
    /// always-hidden apps unless that run is revealed too.
    nonisolated static func concealed(apps: [String: MenuBarItemSection],
                                      revealed: Set<MenuBarItemSection>) -> Set<String> {
        var out = Set<String>()
        for (bundleID, section) in apps {
            switch section {
            case .hidden where !revealed.contains(.hidden):
                out.insert(bundleID)
            case .alwaysHidden where !revealed.contains(.alwaysHidden):
                out.insert(bundleID)
            default:
                break
            }
        }
        return out
    }

    /// Owners whose extras the agent would otherwise conceal: Focus,
    /// Now Playing and friends are MenuBarAgent items — not entries in
    /// `MBSystemItemIdentifier` — and their hosts are not regular
    /// running apps, so they never reach the allowlist on their own.
    /// The system's items are never ours: the whole family stays.
    nonisolated static let systemItemOwners: Set<String> = [
        "com.apple.MenuBarAgent",
        "com.apple.controlcenter",
        "com.apple.TextInputMenuAgent",
    ]

    /// The allowlist that conceals exactly `concealed` among `running`:
    /// everything running that is not concealed, plus the system-item
    /// owners. Sorted so two plans with the same content compare equal.
    nonisolated static func allowlist(running: Set<String>, concealed: Set<String>) -> [String] {
        running.union(systemItemOwners).subtracting(concealed).sorted()
    }

    /// The first app map, taken once from the spacer model's plan: the
    /// apps whose items sat left of the JR-Bar icon become hidden, the
    /// always-hidden overrides carry over. Protected owners (the
    /// system's items) and apps without a bundle identifier (a bare
    /// helper process the agent can never conceal) are skipped.
    nonisolated static func seed(hidden: [(item: MenuBarItem, bundleID: String?)],
                                 alwaysHidden: [(item: MenuBarItem, bundleID: String?)],
                                 own bundleID: String) -> [String: MenuBarItemSection] {
        var map: [String: MenuBarItemSection] = [:]
        for (item, id) in hidden {
            guard let id, id != bundleID, !MenuBarItemLister.isProtected(item) else { continue }
            map[id] = .hidden
        }
        for (item, id) in alwaysHidden {
            guard let id, id != bundleID, !MenuBarItemLister.isProtected(item) else { continue }
            map[id] = .alwaysHidden
        }
        return map
    }

    /// The system items the agent bridges a click for: its own clock,
    /// battery and Wi-Fi ignore a press under any assertion (measured
    /// on 27.0); Control Center answers an Accessibility press without
    /// a lift, and the « never stands while nothing overflows.
    nonisolated static let bridgedIdentifiers: Set<String> = [
        "com.apple.menuextra.clock",
        "com.apple.menuextra.battery",
        "com.apple.menuextra.wifi",
        "com.apple.menuextra.bluetooth",
        "com.apple.menuextra.sound",
        "com.apple.menuextra.display",
        "com.apple.menuextra.displays",
        "com.apple.menuextra.screen-mirroring",
    ]

    /// Whether a click at `point` (Quartz) lands on a bridged system
    /// item.
    nonisolated static func bridgedItem(at point: CGPoint, items: [MenuBarItem]) -> MenuBarItem? {
        items.first {
            $0.bounds.contains(point) && MenuBarItemLister.isProtected($0)
                && $0.identifier.map(bridgedIdentifiers.contains) == true
        }
    }
}

// MARK: - The private API

/// One live assertion — the handle the agent hands back. Process-bound:
/// the agent restores the bar itself when the process dies. Immutable;
/// the helper backend hands it across a pipe-readability closure.
final class MenuBarAssertionToken: @unchecked Sendable {
    let object: AnyObject
    init(_ object: AnyObject) { self.object = object }
}

/// The runtime face of `MenuBarClientCore`'s assessment mode. Every
/// symbol is looked up by name; nothing links against the framework.
@MainActor
protocol MenuBarConcealBackend: AnyObject {
    func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken
    func invalidate(_ token: MenuBarAssertionToken)
    /// A dead token no longer conceals — the in-process assertion lives
    /// as long as the concealer, so the default says alive; the helper
    /// backend's token is a process that can die on its own.
    func isAlive(_ token: MenuBarAssertionToken) -> Bool
}

extension MenuBarConcealBackend {
    func isAlive(_ token: MenuBarAssertionToken) -> Bool { true }
}

@MainActor
final class MenuBarAssessmentBackend: MenuBarConcealBackend {
    enum Failure: Error, CustomStringConvertible {
        case unavailable
        case rejected(String)
        case timedOut
        var description: String {
            switch self {
            case .unavailable: "MenuBarClientCore did not resolve"
            case .rejected(let why): "MenuBarAgent refused the assertion: \(why)"
            case .timedOut: "MenuBarAgent did not answer in 3 s"
            }
        }
    }

    nonisolated private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    nonisolated private static let configurationSelector =
        NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    nonisolated private static let activateSelector =
        NSSelectorFromString("activateWithConfiguration:completionHandler:")
    nonisolated private static let invalidateSelector = NSSelectorFromString("invalidate")
    /// `MBSystemItemIdentifier` 0…8 on 27.0 — battery, Bluetooth, clock,
    /// displays, keyboard, volume, Wi-Fi, screen mirroring, Control
    /// Center. All of them stay: the system's items are never ours.
    nonisolated private static let allSystemItems: [Int] = Array(0...8)

    nonisolated private static let classes: (configuration: AnyClass, assertion: AnyClass)? = {
        guard dlopen(frameworkPath, RTLD_NOW) != nil,
              let configuration = NSClassFromString("MBAssessmentModeConfiguration"),
              let assertion = NSClassFromString("MBAssessmentModeAssertion"),
              configuration.instancesRespond(to: configurationSelector),
              assertion.instancesRespond(to: activateSelector),
              assertion.instancesRespond(to: invalidateSelector) else { return nil }
        return (configuration, assertion)
    }()

    /// Whether this macOS build offers the mechanism.
    nonisolated static var isAvailable: Bool { classes != nil }

    /// Whether this app bundle passes Gatekeeper — notarized. Measured
    /// on 27.0 (26A428): an allowlisted app stays on the bar under an
    /// assertion only when it does; an unnotarized Developer ID build
    /// is concealed along with everything else, its own icon included.
    /// One `spctl` run per launch, off the main actor.
    nonisolated static func bundleIsNotarized() async -> Bool {
        let path = Bundle.main.bundlePath
        return await Task.detached(priority: .utility) { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
            process.arguments = ["--assess", "--verbose=2", "--type", "execute", path]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return output.contains("source=Notarized")
        }.value
    }

    nonisolated static let log = Logger(subsystem: "devin.jrbar", category: "menubar")

    final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
    }

    func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
        guard let classes = Self.classes else { throw Failure.unavailable }
        let allocSelector = NSSelectorFromString("alloc")
        guard let configuration = (classes.configuration as AnyObject).perform(allocSelector)?
                .takeUnretainedValue()
                .perform(Self.configurationSelector,
                         with: Self.allSystemItems.map { NSNumber(value: $0) } as NSArray,
                         with: allowedBundleIDs as NSArray)?
                .takeUnretainedValue(),
              let assertion = (classes.assertion as AnyObject).perform(allocSelector)?
                .takeUnretainedValue()
                .perform(NSSelectorFromString("init"))?
                .takeUnretainedValue() else { throw Failure.unavailable }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = OnceFlag()
                let completion: @convention(block) (Any?) -> Void = { error in
                    guard once.claim() else { return }
                    if let error {
                        continuation.resume(throwing: Failure.rejected(String(describing: error)))
                    } else {
                        continuation.resume()
                    }
                }
                _ = assertion.perform(Self.activateSelector, with: configuration, with: completion)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard once.claim() else { return }
                    continuation.resume(throwing: Failure.timedOut)
                }
            }
        } catch {
            _ = assertion.perform(Self.invalidateSelector)
            throw error
        }
        return MenuBarAssertionToken(assertion)
    }

    func invalidate(_ token: MenuBarAssertionToken) {
        _ = token.object.perform(Self.invalidateSelector)
    }
}

// MARK: - The helper-process backend

/// The assessment backend that holds the assertion in `jrbar-asserter`.
/// The agent never exempts items that share the asserting process's
/// responsible identity — measured 2026-09-21: the app's own assertion
/// hid its icon no matter the allowlist, and so did a helper we
/// `Process`-spawned (a child answers "who asserts?" with its
/// responsible process — us). A foreign holder allowlisting us kept the
/// icon drawn. The helper is therefore spawned with
/// `responsibility_spawnattrs_setdisclaim`: it answers for itself, and
/// its own bundle (`jrbar-asserter.app`,
/// `com.jonathanreed.jrbar.asserter`) carries the foreign identity.
///
/// One process per activation: the token wraps the pid. Killing it
/// releases the assertion (the agent restores a dead holder's bar), and
/// the helper parks on stdin — the app dying mid-assertion closes that
/// pipe, the helper exits, and nothing stays concealed.
@MainActor
final class MenuBarAsserterBackend: MenuBarConcealBackend {
    /// The helper binary inside the app bundle, or `JRBAR_ASSERTER_BIN`
    /// for a build run outside it. nil when neither exists — unsigned
    /// debug runs then fall back to the in-process backend.
    nonisolated static func resolveHelperURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["JRBAR_ASSERTER_BIN"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/jrbar-asserter.app/Contents/MacOS/jrbar-asserter")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    /// The helper died on its own — the concealer re-arms through this.
    /// nil while a deliberate invalidate lands.
    var onLoss: (@MainActor (MenuBarAssertionToken) -> Void)?

    private let helperURL: URL

    /// A spawned helper — the pid is the whole handle. `kill(0)` is the
    /// liveness probe (EPERM still means alive); SIGTERM ends the hold
    /// exactly like the app's own quit path: stdin EOF, helper exits.
    /// The exit source lives here so the token retaining this object
    /// keeps the watch armed; the exit itself disarms it (see `exited`).
    final class Spawned: @unchecked Sendable {
        let pid: pid_t
        /// Guards the three below: the exit source's handler runs on a
        /// dispatch queue, `terminate` on the main actor, and each pipe
        /// end is taken exactly once — a second `close` of a number the
        /// kernel already reused would close someone else's descriptor.
        private let lock = NSLock()
        private var exitSource: DispatchSourceProcess?
        /// The helper's stdin/stdout — kept on the token's object so the
        /// pipe ends outlive `activate` (closing stdin is the release).
        private var stdin: FileHandle?
        private var stdout: FileHandle?
        init(pid: pid_t, stdin: FileHandle, stdout: FileHandle) {
            self.pid = pid
            self.stdin = stdin
            self.stdout = stdout
        }
        var isRunning: Bool { kill(pid, 0) == 0 || errno == EPERM }
        func arm(_ source: DispatchSourceProcess) {
            lock.withLock { exitSource = source }
        }
        /// The helper writes exactly one line; once it is read, the read
        /// end has no further use.
        func closeStdout() {
            let handle = lock.withLock { () -> FileHandle? in
                defer { stdout = nil }
                return stdout
            }
            try? handle?.close()
        }
        private func closeStdin() {
            let handle = lock.withLock { () -> FileHandle? in
                defer { stdin = nil }
                return stdin
            }
            try? handle?.close()
        }
        /// The process is gone and reaped: cancel the exit source — the
        /// handler holds this object and the source hangs off it, a
        /// cycle that kept every activation's pipe descriptors open for
        /// the app's life (soft limit 256) — and close both pipe ends.
        /// A helper that died on its own never saw `terminate`, so its
        /// stdin is closed here too.
        func exited() {
            let source = lock.withLock { () -> DispatchSourceProcess? in
                defer { exitSource = nil }
                return exitSource
            }
            source?.cancel()
            closeStdin()
            closeStdout()
        }
        /// stdin EOF is the designed release — the helper exits on its
        /// own. SIGKILL is the hammer: SIGTERM arrives on the parent's
        /// inherited disposition, which this app ignores, and seven
        /// orphaned asserters proved it (measured 2026-09-21).
        func terminate() {
            closeStdin()
            kill(pid, SIGKILL)
            reapWhenItExits()
        }
        /// Reap a helper that died before `watch` armed — an
        /// un-`waitpid`ed child lingers as a zombie. ECHILD means the
        /// exit source's handler already reaped it: stop there rather
        /// than poll a dead pid at 20 Hz for ten seconds.
        func reapWhenItExits() {
            let pid = self.pid
            Task.detached {
                var status = Int32(0)
                for _ in 0..<200 {
                    let reaped = waitpid(pid, &status, WNOHANG)
                    if reaped == pid || (reaped == -1 && errno == ECHILD) { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
    }

    /// The read buffer for the one-line answer — the pipe's
    /// readability handler is Sendable, so the accumulation lives in a
    /// lock-free-enough box: one producer, one consumer, first newline.
    private final class Answer: @unchecked Sendable { var data = Data() }

    /// `Process` gives no way to disclaim responsibility, so the spawn
    /// is done by hand: two pipes wired onto the helper's stdin/stdout,
    /// every other descriptor closed (CLOEXEC_DEFAULT), the disclaim
    /// attribute making the child its own responsible process.
    private func spawn() throws -> (Spawned, FileHandle, FileHandle) {
        var inFD: [Int32] = [0, 0]
        var outFD: [Int32] = [0, 0]
        guard pipe(&inFD) == 0, pipe(&outFD) == 0 else {
            throw MenuBarAssessmentBackend.Failure.unavailable
        }
        let attr = UnsafeMutablePointer<posix_spawnattr_t?>.allocate(capacity: 1)
        posix_spawnattr_init(attr)
        defer { posix_spawnattr_destroy(attr); attr.deallocate() }
        _ = disclaimResponsibility(attr, 1)
        _ = posix_spawnattr_setflags(attr, CShort(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let actions = UnsafeMutablePointer<posix_spawn_file_actions_t?>.allocate(capacity: 1)
        posix_spawn_file_actions_init(actions)
        defer { posix_spawn_file_actions_destroy(actions); actions.deallocate() }
        posix_spawn_file_actions_adddup2(actions, inFD[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(actions, outFD[1], STDOUT_FILENO)
        let path = helperURL.path
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(argv[0]) }
        var pid = pid_t()
        let envp = _nsGetEnviron()?.pointee
        let rc = posix_spawn(&pid, path, UnsafePointer(actions), UnsafePointer(attr), argv, envp)
        close(inFD[0])
        close(outFD[1])
        guard rc == 0 else {
            close(inFD[1])
            close(outFD[0])
            throw MenuBarAssessmentBackend.Failure.rejected(
                "asserter spawn: \(String(cString: strerror(rc)))")
        }
        let stdin = FileHandle(fileDescriptor: inFD[1], closeOnDealloc: true)
        let stdout = FileHandle(fileDescriptor: outFD[0], closeOnDealloc: true)
        return (Spawned(pid: pid, stdin: stdin, stdout: stdout), stdin, stdout)
    }

    nonisolated init(helperURL: URL) { self.helperURL = helperURL }

    func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
        let (spawned, stdin, stdout) = try spawn()
        guard let payload = try? JSONSerialization.data(withJSONObject: allowedBundleIDs),
              let line = String(data: payload, encoding: .utf8) else {
            spawned.terminate()
            throw MenuBarAssessmentBackend.Failure.unavailable
        }
        stdin.write((line + "\n").data(using: .utf8)!)

        let token = MenuBarAssertionToken(spawned)
        return try await withCheckedThrowingContinuation { continuation in
            let once = MenuBarAssessmentBackend.OnceFlag()
            let answer = Answer()
            stdout.readabilityHandler = { [self] handle in
                answer.data.append(handle.availableData)
                guard answer.data.contains(0x0A) else { return }
                handle.readabilityHandler = nil
                guard once.claim() else { return }
                // One line is the whole answer; the read end is spent.
                spawned.closeStdout()
                let text = String(decoding: answer.data, as: UTF8.self)
                if text.hasPrefix("ok") {
                    watch(spawned, token: token)
                    continuation.resume(returning: token)
                } else {
                    spawned.terminate()
                    continuation.resume(throwing: MenuBarAssessmentBackend.Failure.rejected(
                        text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            // The helper's own 3 s timeout writes its line at about this
            // moment, so a readability pass may still be in flight: stdout
            // is not closed under it here. Nothing was armed, so nothing
            // holds `spawned` past this closure — the handle closes on
            // dealloc.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard once.claim() else { return }
                stdout.readabilityHandler = nil
                spawned.terminate()
                continuation.resume(throwing: MenuBarAssessmentBackend.Failure.timedOut)
            }
        }
    }

    /// Follow the helper's exit: a loss the concealer did not ask for is
    /// news — the assertion it stood for died with the process. The
    /// dispatch source also reaps the pid so it never lingers as a
    /// zombie, then disarms itself (`Spawned.exited`).
    nonisolated private func watch(_ spawned: Spawned, token: MenuBarAssertionToken) {
        let pid = spawned.pid
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)
        source.setEventHandler { [weak self] in
            var status = Int32(0)
            _ = waitpid(pid, &status, 0)
            spawned.exited()
            Task { @MainActor in self?.onLoss?(token) }
        }
        spawned.arm(source)
        source.resume()
    }

    func invalidate(_ token: MenuBarAssertionToken) {
        (token.object as? Spawned)?.terminate()
    }

    func isAlive(_ token: MenuBarAssertionToken) -> Bool {
        (token.object as? Spawned)?.isRunning ?? false
    }
}

/// "Be your own responsible process" — the spawn attribute that keeps
/// the assertion the helper holds from answering with the app's bundle
/// identity. libSystem export; no header ships it.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func disclaimResponsibility(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>?,
                                    _ disclaim: CInt) -> CInt

/// The inherited environment for `posix_spawn` — no public Swift name.
@_silgen_name("_NSGetEnviron")
private func _nsGetEnviron()
    -> UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>?

// MARK: - The controller

/// Keeps one live assertion in step with a target concealed set.
/// `apply` is serialized: a call that lands while one is in flight
/// waits its turn, so the bar never sees two half-transitions.
@MainActor
final class MenuBarConcealer {
    private struct Live {
        let concealed: Set<String>
        let allowlist: [String]
        let token: MenuBarAssertionToken
    }

    private let backend: any MenuBarConcealBackend
    private var live: Live?
    private var queue: Task<Void, Never>?
    /// The live suspend's restore — an apply that lands inside the
    /// window waits it out rather than converging mid-lift. Cleared
    /// when the window closes, so `isSuspended` is a real state and
    /// an old window never outlives its restore.
    private var suspendWindow: Task<Void, Never>?
    /// Which window the clear below belongs to — a second suspend
    /// overwriting `suspendWindow` must not let the first's watcher
    /// end the new window early.
    private var suspendGeneration = 0
    /// The last set asked for — what a suspend restores.
    private(set) var target: Set<String> = []
    private(set) var running: Set<String> = []
    /// Every bundle ID observed running this session — the allowlist's
    /// universe. Monotonic: a snapshot that drops a shown app for one
    /// pass never shrinks it, so a bad listing can't conceal a shown
    /// app for a cycle; a terminated app has no items to protect, so
    /// its entry costs nothing and never forces a re-assert.
    private var seenRunning: Set<String> = []
    /// Arrival order for `seenRunning` — the cap sheds the oldest
    /// entries no longer seen first.
    private var seenOrder: [String] = []
    /// Beyond this many remembered bundle IDs, prune.
    nonisolated static let seenRunningCap = 512
    /// The last failure, for the card. nil while the agent answers.
    private(set) var lastError: String?
    var onChange: (@MainActor () -> Void)?

    /// The assertion-free beat a newly registered item needs to be
    /// adopted by the agent.
    nonisolated static let adoptionBeat: TimeInterval = 0.35

    /// The shipped backend: the helper process when its binary rides in
    /// the bundle, the in-process assertion otherwise (dev runs conceal
    /// fine either way — the helper is what keeps the icon drawn).
    nonisolated static func defaultBackend() -> any MenuBarConcealBackend {
        if let helper = MenuBarAsserterBackend.resolveHelperURL() {
            return MenuBarAsserterBackend(helperURL: helper)
        }
        return MenuBarAssessmentBackend()
    }

    init(backend: any MenuBarConcealBackend = MenuBarConcealer.defaultBackend()) {
        self.backend = backend
        if let helper = backend as? MenuBarAsserterBackend {
            helper.onLoss = { [weak self] token in
                self?.asserterLost(token)
            }
        }
        // The universe starts with the system-item owners and our own
        // bundle: both belong on every allowlist this session issues.
        seenOrder = MenuBarConcealPlan.systemItemOwners.sorted()
        seenRunning = MenuBarConcealPlan.systemItemOwners
        if let own = Bundle.main.bundleIdentifier {
            seenOrder.append(own)
            seenRunning.insert(own)
        }
    }

    var isConcealing: Bool { live != nil }
    /// True while a suspend window is open — concealment is lifted but
    /// coming back. A lift is not a teardown: readers that wipe state
    /// when `isConcealing` drops must keep it through this.
    var isSuspended: Bool { suspendWindow != nil }
    var concealedApps: Set<String> { live?.concealed ?? [] }

    /// Conceal exactly `concealed` among `running`. An empty set
    /// releases everything — no assertion at all, so the system's
    /// items take clicks natively again.
    func apply(concealed: Set<String>, running: Set<String>) {
        target = concealed
        self.running = running
        // The allowlist's universe only grows: anything the workspace
        // has ever shown us stays allowlisted until the cap, so the
        // agent always has the ID it needs to keep a shown app on the
        // row — and a re-assert happens only for real growth.
        for id in running where !seenRunning.contains(id) { seenOrder.append(id) }
        seenRunning.formUnion(running)
        if seenRunning.count > Self.seenRunningCap {
            let own = Bundle.main.bundleIdentifier
            let droppable = seenOrder.filter {
                !running.contains($0) && !MenuBarConcealPlan.systemItemOwners.contains($0)
                    && $0 != own
            }
            for id in droppable.prefix(seenRunning.count - Self.seenRunningCap) {
                seenRunning.remove(id)
            }
            seenOrder = seenOrder.filter { seenRunning.contains($0) }
        }
        // The window is captured at call time: a suspend that starts
        // after this apply already queues its drop behind it, so only
        // a window open *now* must be waited out — and awaiting it
        // inside the task can never close a cycle.
        let window = suspendWindow
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await window?.value
            await self?.converge()
        }
    }

    /// Everything back — the deliberate release (a disable, a quit).
    /// The live assertion drops immediately so a quit never leaves the
    /// bar concealed for the drain, then queued work gets a short
    /// grace to unwind: an activation in flight sees the empty target
    /// and stands down instead of re-concealing behind us.
    func releaseAll() async {
        target = []
        dropLive()
        if let pending = queue {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await pending.value }
                group.addTask { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                _ = await group.next()
                group.cancelAll()
            }
        }
    }

    /// Re-activate with the live configuration. An item registered
    /// while an assertion holds is not adopted, so a concealed app
    /// that re-creates its status item stands on the row until a
    /// fresh activation sweeps it. New token before the old one is
    /// invalidated — concealment never lifts mid-sweep.
    func reassert() {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self, let live = self.live else { return }
            do {
                let token = try await self.backend.activate(allowedBundleIDs: live.allowlist)
                // The token this sweep was meant to replace may have
                // been released — or re-converged — while the agent
                // answered; never resurrect what is already gone.
                guard self.live?.token === live.token else {
                    self.backend.invalidate(token)
                    return
                }
                self.live = Live(concealed: live.concealed, allowlist: live.allowlist, token: token)
                self.backend.invalidate(live.token)
                MenuBarAssessmentBackend.log.notice("reassert: reswept \(live.concealed.count, privacy: .public) apps")
            } catch {
                self.lastError = String(describing: error)
            }
        }
    }

    /// Lift concealment for `interval` and put it back: the click
    /// bridge's window. Returns once the lift has landed. The window
    /// is recorded before the drop is even queued, so an apply that
    /// lands anywhere inside it — before, during or after the lift —
    /// waits the restore out rather than converging mid-window.
    func suspend(for interval: TimeInterval) async {
        let previous = queue
        let drop = Task { [weak self] in
            await previous?.value
            self?.dropLive()
        }
        let restore = Task { [weak self] in
            await drop.value
            try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
            await self?.converge()
        }
        suspendWindow = restore
        queue = restore
        suspendGeneration += 1
        let generation = suspendGeneration
        Task { [weak self] in
            await restore.value
            guard let self, self.suspendGeneration == generation else { return }
            self.suspendWindow = nil
        }
        await drop.value
    }

    private func converge() async {
        let concealed = target.intersection(seenRunning)
        if concealed.isEmpty {
            dropLive()
            return
        }
        let allowlist = MenuBarConcealPlan.allowlist(running: seenRunning, concealed: concealed)
        // Re-assert only for real news: a first-seen app joining the
        // allowlist, or a changed concealed set. A quit, a snapshot
        // blip, a re-read of the same universe — the live assertion
        // already covers all of those, so it stays.
        if let live, live.concealed == concealed,
           Set(allowlist).isSubset(of: Set(live.allowlist)),
           backend.isAlive(live.token) { return }
        do {
            let token = try await backend.activate(allowedBundleIDs: allowlist)
            // A release or retarget that landed mid-activation wins:
            // the plan this token was built for no longer stands, so
            // it goes straight back rather than resurrecting a
            // concealment the caller already dropped.
            guard target.intersection(seenRunning) == concealed else {
                backend.invalidate(token)
                return
            }
            let old = live
            live = Live(concealed: concealed, allowlist: allowlist, token: token)
            if let old { backend.invalidate(old.token) }
            lastError = nil
            MenuBarAssessmentBackend.log.notice("conceal: \(concealed.count, privacy: .public) apps hidden by the agent (\(concealed.sorted().joined(separator: ", "), privacy: .public)); allowlist \(allowlist.count, privacy: .public) apps, ours \(allowlist.contains(Bundle.main.bundleIdentifier ?? "-") ? "in" : "MISSING", privacy: .public)")
        } catch {
            lastError = String(describing: error)
            MenuBarAssessmentBackend.log.error("conceal: \(String(describing: error), privacy: .public)")
        }
        onChange?()
    }

    /// The helper holding the live assertion exited on its own. A
    /// deliberate invalidate clears `live` before the process's
    /// termination handler runs, so a token that still matches `live`
    /// is a real loss — the bar is unconcealed and must re-arm.
    private func asserterLost(_ token: MenuBarAssertionToken) {
        guard let live, live.token === token else { return }
        self.live = nil
        MenuBarAssessmentBackend.log.error("conceal: asserter died — rearming")
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await self?.converge()
        }
    }

    private func dropLive() {
        guard let live else { return }
        backend.invalidate(live.token)
        self.live = nil
        MenuBarAssessmentBackend.log.notice("conceal: released")
        onChange?()
    }
}

// MARK: - The click bridge

/// While an assertion is live the agent ignores a click on its own
/// clock, battery or Wi-Fi. The bridge holds such a click back at the
/// session event tap, lifts concealment, replays the click at the
/// same point (the pointer never moves), and lets concealment return
/// a moment later. Replays carry a marker so the tap passes them.
final class MenuBarSystemClickBridge: @unchecked Sendable {
    nonisolated static let replayMarker: Int64 = 0x4A52_4241_5231
    /// The lift a replay needs before the agent will act on it — 80 ms
    /// lost none of sixteen clicks in Ice's measurement; 100 leaves
    /// room.
    nonisolated static let liftDelay: TimeInterval = 0.10
    /// How long concealment stays lifted after the replay — the clock's
    /// panel opens ~166 ms after its click; it stays open when
    /// concealment returns.
    nonisolated static let liftWindow: TimeInterval = 0.45

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var items: [MenuBarItem] = []
    private var concealing = false
    private var swallowUp = false
    /// Whether the event tap is live — `tapCreate` refuses without the
    /// Accessibility grant, and the card reads this to say so instead
    /// of silently no-opping. Written on the main thread by
    /// `start`/`stop`, read there too.
    private(set) var tapLive = false
    private let onBridge: @MainActor (CGPoint) -> Void

    init(onBridge: @escaping @MainActor (CGPoint) -> Void) {
        self.onBridge = onBridge
    }

    /// The listing's protected items and whether an assertion is live —
    /// the tap reads copies under the lock.
    func update(items: [MenuBarItem], concealing: Bool) {
        lock.withLock {
            self.items = items.filter { MenuBarItemLister.isProtected($0) }
            self.concealing = concealing
        }
    }

    func start() {
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let bridge = Unmanaged<MenuBarSystemClickBridge>.fromOpaque(info).takeUnretainedValue()
                return bridge.handle(type: type, event: event)
            },
            userInfo: pointer) else {
            MenuBarAssessmentBackend.log.error("click bridge: no event tap — system item clicks stay native")
            tapLive = false
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapLive = true
    }

    func stop() {
        tapLive = false
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker {
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseUp {
            let eat = lock.withLock { () -> Bool in
                defer { swallowUp = false }
                return swallowUp
            }
            return eat ? nil : Unmanaged.passUnretained(event)
        }
        let point = event.location
        let hit: Bool = lock.withLock {
            guard concealing else { return false }
            return MenuBarConcealPlan.bridgedItem(at: point, items: items) != nil
        }
        guard hit else { return Unmanaged.passUnretained(event) }
        lock.withLock { swallowUp = true }
        let onBridge = onBridge
        Task { @MainActor in onBridge(point) }
        return nil
    }

    /// One synthetic click at `point`, tagged so the tap lets it pass.
    nonisolated static func replay(at point: CGPoint) {
        for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: kind,
                                      mouseCursorPosition: point, mouseButton: .left) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
