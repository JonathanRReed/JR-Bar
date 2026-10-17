import Darwin
import Foundation

/// Runs the core daemon as a child process and keeps it alive.
///
/// `start()` spawns the executable with stdout and stderr captured line by
/// line into `onOutput`. When the child exits on its own the supervisor
/// restarts it on the protocol's backoff schedule (0.5 s, 1 s, 2 s, 4 s,
/// then 5 s), unless `maxFailures` exits landed inside `failureWindow`, in
/// which case it gives up and reports `.crashed` until someone calls
/// `restart()`. `stop()` sends SIGTERM, waits `gracePeriod`, then SIGKILL.
///
/// With an `authSecret` it also makes a fresh 32-byte secret for every child
/// and hands it over the child's stdin pipe (never its environment or
/// arguments), so only the app can authenticate to the daemon's socket
/// (docs/CORE-PROTOCOL.md, "Who may send what"). With a `sealKey` provider the
/// same pipe carries the settings seal key after the secret (docs/CORE-PROTOCOL.md,
/// "Protected settings").
///
/// Thread-safe; callbacks arrive on an arbitrary thread.
public final class CoreSupervisor: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case running(pid: Int32)
        /// The child exited; a restart is scheduled after `delay`.
        case backingOff(failures: Int, delay: TimeInterval)
        /// Too many exits in the window; waiting for `restart()`.
        case crashed(failures: Int)
        case stopped
    }

    public struct Exit: Equatable, Sendable {
        public var at: Date
        public var status: Int32
        public var signal: Int32?
    }

    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]?
    public let maxFailures: Int
    public let failureWindow: TimeInterval
    /// Multiplies every backoff delay (tests use a small value).
    public let backoffScale: Double
    /// Where the secret of the running child is kept for the client to prove.
    /// Nil: the child is started with no secret and takes no privileged
    /// commands on its socket.
    public let authSecret: CoreAuthSecret?
    /// The settings seal key for each child, if the app has one. Asked at every
    /// start (the holder keeps it in memory, so this never reads the Keychain
    /// twice). Nil, or a nil answer: the child gets the secret alone.
    public let sealKey: (@Sendable () -> SettingsSealHandoff?)?

    public var onOutput: (@Sendable (_ stream: String, _ line: String) -> Void)?
    public var onStateChange: (@Sendable (State) -> Void)?
    public var onExit: (@Sendable (Exit) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var retiringProcesses: [Process] = []
    private var _state: State = .idle
    private var exits: [Date] = []
    private var restartTimer: DispatchWorkItem?
    private var restartEscalation: DispatchWorkItem?
    private var stopping = false
    private var launching = false
    private var generation = 0
    private let queue = DispatchQueue(label: "jrbar.core.supervisor")
    /// Test seam: replaces `Process.run()` so a test can hold a spawn in
    /// flight and race `stop()` against it.
    var processRunHook: ((Process) throws -> Void)?
    /// Test seam: where a child's secret comes from.
    var secretGenerator: @Sendable () -> Data? = { CoreAuthSecret.generate() }
    /// Tests hold the deadline action and advance it without waiting.
    var restartEscalationHook: (@Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)?

    public init(executable: String, arguments: [String] = [], environment: [String: String]? = nil,
                maxFailures: Int = 10, failureWindow: TimeInterval = 120, backoffScale: Double = 1.0,
                authSecret: CoreAuthSecret? = nil, sealKey: (@Sendable () -> SettingsSealHandoff?)? = nil) {
        self.authSecret = authSecret
        self.sealKey = sealKey
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.maxFailures = maxFailures
        self.failureWindow = failureWindow
        self.backoffScale = backoffScale
    }

    /// `JRBAR_CORE_EXEC="python3 scripts/mock-core.py"` → executable and
    /// arguments. Bare names resolve through `/usr/bin/env`.
    public convenience init?(commandLine: String, environment: [String: String]? = nil, backoffScale: Double = 1.0,
                             authSecret: CoreAuthSecret? = nil, sealKey: (@Sendable () -> SettingsSealHandoff?)? = nil) {
        let words = commandLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first else { return nil }
        let rest = Array(words.dropFirst())
        if first.hasPrefix("/") || first.hasPrefix(".") || first.hasPrefix("~") {
            self.init(executable: NSString(string: first).expandingTildeInPath, arguments: rest, environment: environment,
                      backoffScale: backoffScale, authSecret: authSecret, sealKey: sealKey)
        } else {
            self.init(executable: "/usr/bin/env", arguments: [first] + rest, environment: environment,
                      backoffScale: backoffScale, authSecret: authSecret, sealKey: sealKey)
        }
    }

    /// A supervisor that is let go ends its child without waiting for it:
    /// the SIGKILL is certain, and a destructor can run on the main thread.
    deinit { stop(gracePeriod: 0, waitForExit: false) }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Exits inside the failure window, newest last.
    public var recentFailures: Int {
        lock.lock(); defer { lock.unlock() }
        return prunedExits().count
    }

    // MARK: Lifecycle

    public func start() {
        lock.lock()
        stopping = false
        if process != nil { lock.unlock(); return }
        lock.unlock()
        spawn()
    }

    /// Forgets the failure history and replaces the child without waiting.
    /// A child still running after three seconds is killed on the supervisor queue.
    public func restart() {
        lock.lock()
        exits.removeAll()
        stopping = false
        restartTimer?.cancel()
        restartTimer = nil
        if let running = process, running.isRunning {
            guard restartEscalation == nil else { lock.unlock(); return }
            let expectedGeneration = generation
            let escalate: @Sendable () -> Void = { [weak self] in
                self?.finishRestart(of: running, generation: expectedGeneration)
            }
            let work = DispatchWorkItem(block: escalate)
            restartEscalation = work
            let schedule = restartEscalationHook
            running.terminate()
            lock.unlock()
            if let schedule { schedule(3, escalate) }
            else { queue.asyncAfter(deadline: .now() + 3, execute: work) }
            return
        }
        lock.unlock()
        spawn()
    }

    private func finishRestart(of child: Process, generation expectedGeneration: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !stopping, generation == expectedGeneration, process === child, child.isRunning else { return }
        kill(child.processIdentifier, SIGKILL)
    }

    /// SIGTERM, then SIGKILL after `gracePeriod`. Returns once the child is gone,
    /// unless `waitForExit` is false, which sends the SIGKILL and returns.
    /// Waits on the calling thread: call it off the main thread.
    public func stop(gracePeriod: TimeInterval = 3.0, waitForExit: Bool = true) {
        lock.lock()
        stopping = true
        launching = false
        generation += 1
        let stopGeneration = generation
        authSecret?.set(nil)
        restartTimer?.cancel()
        restartTimer = nil
        restartEscalation?.cancel()
        restartEscalation = nil
        if let process { retiringProcesses.append(process) }
        process = nil
        let retiring = retiringProcesses
        lock.unlock()
        guard !retiring.isEmpty else {
            setState(.stopped, generation: stopGeneration)
            return
        }
        for child in retiring where child.isRunning { child.terminate() }
        let deadline = Date(timeIntervalSinceNow: gracePeriod)
        while retiring.contains(where: { $0.isRunning }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        for child in retiring where child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            if waitForExit { child.waitUntilExit() }
        }
        lock.lock()
        retiringProcesses.removeAll { !$0.isRunning }
        lock.unlock()
        setState(.stopped, generation: stopGeneration)
    }

    // MARK: Spawning

    private func spawn() {
        // Reserve the launch before making a handoff. Concurrent starts must
        // neither create a second child nor replace the first child's secret.
        lock.lock()
        guard !stopping, process == nil, !launching else { lock.unlock(); return }
        launching = true
        generation += 1
        let myGeneration = generation
        restartTimer?.cancel()
        restartTimer = nil
        restartEscalation?.cancel()
        restartEscalation = nil
        lock.unlock()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // The child can tell it is supervised (and by whom) so it can exit
        // if the app dies without unwinding.
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["JRBAR_SUPERVISED"] = "1"
        childEnvironment["JRBAR_SUPERVISOR_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        if let environment { childEnvironment.merge(environment) { _, new in new } }
        // A new child, a new secret: only this child's stdin pipe carries it.
        childEnvironment.removeValue(forKey: Self.handoffEnvironmentKey)
        var handoff: Pipe?
        var childSecret: Data?
        if authSecret != nil {
            let seal = sealKey?()
            if let secret = secretGenerator(), let pipe = Self.makeHandoffPipe(carrying: secret, sealKey: seal?.key) {
                childSecret = secret
                handoff = pipe
                childEnvironment[Self.handoffEnvironmentKey] = Self.handoffAnnouncement(sealKey: seal)
            } else {
                onOutput?("supervisor", "could not make an app secret; the daemon will refuse privileged commands")
            }
        }
        process.environment = childEnvironment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let handoff {
            process.standardInput = handoff
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        let output = CoreProcessOutput(stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading,
                                       queue: queue) { [weak self] stream, line in
            self?.onOutput?(stream, line)
        }
        process.terminationHandler = { [weak self] finished in
            output.finish { [weak self] in self?.childExited(finished, generation: myGeneration) }
        }
        // run() and the `self.process` assignment happen inside ONE
        // critical section. A stop() that lands while the spawn is in
        // flight either ran first (we see `stopping` and never launch) or
        // blocks on the lock until the child is published -- then kills
        // it. Either way an unsupervised orphan is impossible, and
        // `self.process` never holds a child nothing can reach.
        lock.lock()
        guard !stopping, generation == myGeneration else {
            lock.unlock()
            Self.closeHandoff(handoff)
            return
        }
        authSecret?.set(childSecret)
        do {
            try output.start()
            try (processRunHook ?? { try $0.run() })(process)
        } catch {
            launching = false
            authSecret?.set(nil)
            lock.unlock()
            output.finish {}
            Self.closeHandoff(handoff)
            onOutput?("supervisor", "cannot launch \(executable): \(error)")
            recordFailure(generation: myGeneration)
            return
        }
        // The child holds its end now; this process keeps neither.
        Self.closeHandoff(handoff)
        self.process = process
        launching = false
        let pid = process.processIdentifier
        authSecret?.setDaemonPID(pid)
        let newState = State.running(pid: pid)
        let changed = _state != newState
        _state = newState
        lock.unlock()
        onOutput?("supervisor", "core started (pid \(pid))")
        // The state was committed under the lock; only announce it if a
        // racing stop() has not already published `.stopped`.
        if changed, state == newState { onStateChange?(newState) }
    }

    private func childExited(_ process: Process, generation: Int) {
        let signal: Int32? = process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil
        let exit = Exit(at: Date(), status: process.terminationStatus, signal: signal)
        onExit?(exit)
        lock.lock()
        retiringProcesses.removeAll { $0 === process }
        let current = self.generation == generation
        let stopping = self.stopping
        // Clear `self.process` whenever THIS child is the one it holds --
        // even when a stop() bumped the generation -- so `start()` is
        // never blocked by a reference to a dead child. A respawn that
        // already replaced the reference is left alone.
        let held = self.process === process
        if held {
            restartEscalation?.cancel()
            restartEscalation = nil
            self.process = nil
            authSecret?.set(nil)
        }
        lock.unlock()
        if let signal {
            onOutput?("supervisor", "core exited on signal \(signal)")
        } else {
            onOutput?("supervisor", "core exited with status \(process.terminationStatus)")
        }
        guard current, !stopping else { return }
        recordFailure(generation: generation)
    }

    private func recordFailure(generation expectedGeneration: Int) {
        lock.lock()
        guard generation == expectedGeneration, !stopping, process == nil, !launching else {
            lock.unlock()
            return
        }
        exits.append(Date())
        let recent = prunedExits()
        exits = recent
        let failures = recent.count
        if failures >= maxFailures {
            let newState = State.crashed(failures: failures)
            let changed = _state != newState
            _state = newState
            lock.unlock()
            onOutput?("supervisor", "core crashed \(failures) times in \(Int(failureWindow)) s; giving up")
            if changed, state == newState { onStateChange?(newState) }
            return
        }
        let delay = CoreBackoff.delay(afterFailures: failures) * backoffScale
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let cancelled = self.stopping || self.process != nil || self.launching
                || self.generation != expectedGeneration
            if self.generation == expectedGeneration { self.restartTimer = nil }
            self.lock.unlock()
            if !cancelled { self.spawn() }
        }
        restartTimer?.cancel()
        restartTimer = work
        let newState = State.backingOff(failures: failures, delay: delay)
        let changed = _state != newState
        _state = newState
        lock.unlock()
        if changed, state == newState { onStateChange?(newState) }
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func prunedExits() -> [Date] {
        let cutoff = Date(timeIntervalSinceNow: -failureWindow)
        return exits.filter { $0 >= cutoff }
    }

    private func setState(_ new: State, generation expectedGeneration: Int) {
        lock.lock()
        guard generation == expectedGeneration else { lock.unlock(); return }
        let changed = _state != new
        _state = new
        lock.unlock()
        if changed, state == new { onStateChange?(new) }
    }

    // MARK: Secret hand-off

    /// Names the child's stdin as the secret's pipe; the daemon reads exactly
    /// 32 bytes from it once (64 with a seal key) and then points stdin at
    /// /dev/null. The variable names a channel and carries no secret.
    static let handoffEnvironmentKey = "JRBAR_AUTH_STDIN"

    /// What the variable says the pipe holds: "1" the secret alone, "2" the
    /// secret and a seal key that has sealed the settings before, "3" the
    /// secret and a seal key that has sealed nothing yet.
    static func handoffAnnouncement(sealKey: SettingsSealHandoff?) -> String {
        guard let sealKey else { return "1" }
        return sealKey.isNew ? "3" : "2"
    }

    /// A pipe that already holds `secret` (then `sealKey`) and whose write end
    /// is closed, so the child reads those bytes and then end-of-file. Both
    /// ends are close-on-exec in this process, so no other child it starts
    /// inherits either; only the dup onto the daemon's stdin survives its exec.
    static func makeHandoffPipe(carrying secret: Data, sealKey: Data? = nil) -> Pipe? {
        let pipe = Pipe()
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            let flags = fcntl(handle.fileDescriptor, F_GETFD)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else { return nil }
        }
        do {
            try pipe.fileHandleForWriting.write(contentsOf: secret + (sealKey ?? Data()))
            try pipe.fileHandleForWriting.close()
        } catch {
            try? pipe.fileHandleForReading.close()
            return nil
        }
        return pipe
    }

    private static func closeHandoff(_ pipe: Pipe?) {
        try? pipe?.fileHandleForReading.close()
    }

}

// MARK: - Serve token

/// `~/.local/state/jrbar/serve-token`: the bearer the loopback status
/// endpoint requires. Generated once (0600, user-only), reused across
/// launches so a Stream Deck config written against it keeps working.
public enum ServeToken {
    public static var path: String {
        let socketPath = CoreSocketPath.resolve()
        return (socketPath as NSString).deletingLastPathComponent + "/serve-token"
    }

    /// Reads the persisted token, generating and storing one on first use.
    /// Returns nil when the state directory cannot be written.
    public static func load() -> String? { load(at: path) }

    /// The token at `path`. Only a private regular file of ours is read: a
    /// link is not followed, and a file others can read or write is
    /// replaced by a fresh token, since it may have been seen.
    static func load(at path: String) -> String? {
        if let token = readPrivateToken(at: path) { return token }
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path) // removes a link or a loose file itself, never what a link points at
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let bytes = Array(token.utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { return nil }
        return token
    }

    private static func readPrivateToken(at path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        guard read(fd, &buffer, buffer.count) == buffer.count,
              let text = String(bytes: buffer, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.count >= 24 ? token : nil
    }
}

// MARK: - The bundled daemon

extension CoreSupervisor {
    /// What a packaged `JR-Bar.app` carries under `Contents/Helpers`: the
    /// frozen daemon (`jrbar-core.app/Contents/MacOS/jrbar-core`, one binary
    /// that serves `core`, `agent-monitor install all`, `hooks doctor` and
    /// `doctor`) and the compiled hook shim (`jrbar-hook`). `commit` is the
    /// `JRBarCommit` Info.plist key the packager writes; the daemon reports
    /// it in its doctor reply.
    public struct BundledCore: Equatable, Sendable {
        public var executable: String
        public var hookShim: String
        public var version: String?
        public var commit: String?
        public var buildNumber: String?

        public init(executable: String, hookShim: String, version: String? = nil, commit: String? = nil,
                    buildNumber: String? = nil) {
            self.executable = executable
            self.hookShim = hookShim
            self.version = version
            self.commit = commit
            self.buildNumber = buildNumber
        }

        /// The environment every invocation of the bundled binary gets: the
        /// shim every provider hook must run, the commit for `doctor`, and
        /// the status endpoint's bearer token so `serve` can authenticate.
        public var environment: [String: String] {
            var environment = ["JRBAR_HOOK_EXEC": hookShim, "PYTHONUNBUFFERED": "1"]
            if let commit { environment["JRBAR_COMMIT"] = commit }
            if let token = ServeToken.load() { environment["JRBAR_SERVE_ACCESS_TOKEN"] = token }
            return environment
        }

        /// A stamp that changes with every packaged build and with the bundle's
        /// location: the app installs provider hooks once per stamp. The hooks
        /// run a launcher that points at this bundle's shim, so moving the app
        /// between `~/Applications` and `/Applications` has to refresh them.
        public var buildStamp: String {
            "\(version ?? "?")@\(commit ?? "?")@\(hookShim)@build=\(buildNumber ?? "?")"
        }
    }

    /// The daemon and shim inside `bundlePath` (an app bundle), or nil when
    /// the bundle does not carry them (a `swift run`, the dev bundle).
    public static func bundledCore(bundlePath: String, info: [String: Any]? = nil,
                                   fileManager: FileManager = .default) -> BundledCore? {
        let helpers = (bundlePath as NSString).appendingPathComponent("Contents/Helpers")
        let executable = (helpers as NSString).appendingPathComponent("jrbar-core.app/Contents/MacOS/jrbar-core")
        let shim = (helpers as NSString).appendingPathComponent("jrbar-hook")
        guard fileManager.isExecutableFile(atPath: executable), fileManager.isExecutableFile(atPath: shim) else {
            return nil
        }
        return BundledCore(
            executable: executable,
            hookShim: shim,
            version: info?["CFBundleShortVersionString"] as? String,
            commit: info?["JRBarCommit"] as? String,
            buildNumber: info?["CFBundleVersion"] as? String
        )
    }

    /// The bundled daemon of the running app, if this is a packaged bundle.
    public static func bundledCore(in bundle: Bundle) -> BundledCore? {
        bundledCore(bundlePath: bundle.bundlePath, info: bundle.infoDictionary)
    }

    /// Supervises the bundled daemon: `jrbar-core core` with the shim and
    /// commit in its environment (plus `JRBAR_SUPERVISED=1` from `spawn`).
    public convenience init(bundled: BundledCore, backoffScale: Double = 1.0, authSecret: CoreAuthSecret? = nil,
                            sealKey: (@Sendable () -> SettingsSealHandoff?)? = nil) {
        self.init(executable: bundled.executable, arguments: ["core"], environment: bundled.environment,
                  backoffScale: backoffScale, authSecret: authSecret, sealKey: sealKey)
    }
}
