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

    public var onOutput: (@Sendable (_ stream: String, _ line: String) -> Void)?
    public var onStateChange: (@Sendable (State) -> Void)?
    public var onExit: (@Sendable (Exit) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var _state: State = .idle
    private var exits: [Date] = []
    private var restartTimer: DispatchWorkItem?
    private var stopping = false
    private var generation = 0
    private var stdoutRemainder = ""
    private var stderrRemainder = ""
    private let queue = DispatchQueue(label: "jrbar.core.supervisor")

    public init(executable: String, arguments: [String] = [], environment: [String: String]? = nil,
                maxFailures: Int = 10, failureWindow: TimeInterval = 120, backoffScale: Double = 1.0) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.maxFailures = maxFailures
        self.failureWindow = failureWindow
        self.backoffScale = backoffScale
    }

    /// `JRBAR_CORE_EXEC="python3 scripts/mock-core.py"` → executable and
    /// arguments. Bare names resolve through `/usr/bin/env`.
    public convenience init?(commandLine: String, environment: [String: String]? = nil, backoffScale: Double = 1.0) {
        let words = commandLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first else { return nil }
        let rest = Array(words.dropFirst())
        if first.hasPrefix("/") || first.hasPrefix(".") || first.hasPrefix("~") {
            self.init(executable: NSString(string: first).expandingTildeInPath, arguments: rest, environment: environment, backoffScale: backoffScale)
        } else {
            self.init(executable: "/usr/bin/env", arguments: [first] + rest, environment: environment, backoffScale: backoffScale)
        }
    }

    deinit { stop(gracePeriod: 0) }

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

    /// Forgets the failure history and starts again (the panel's Restart button).
    public func restart() {
        lock.lock()
        exits.removeAll()
        stopping = false
        restartTimer?.cancel()
        restartTimer = nil
        let running = process
        lock.unlock()
        if let running, running.isRunning {
            // A live child is replaced: terminate it and let the exit handler respawn.
            running.terminate()
            return
        }
        spawn()
    }

    /// SIGTERM, then SIGKILL after `gracePeriod`. Returns once the child is gone.
    public func stop(gracePeriod: TimeInterval = 3.0) {
        lock.lock()
        stopping = true
        generation += 1
        restartTimer?.cancel()
        restartTimer = nil
        let running = process
        process = nil
        lock.unlock()
        guard let running else {
            setState(.stopped)
            return
        }
        if running.isRunning {
            running.terminate()
            let deadline = Date(timeIntervalSinceNow: gracePeriod)
            while running.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if running.isRunning {
                kill(running.processIdentifier, SIGKILL)
                running.waitUntilExit()
            }
        }
        setState(.stopped)
    }

    // MARK: Spawning

    private func spawn() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // The child can tell it is supervised (and by whom) so it can exit
        // if the app dies without unwinding.
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["JRBAR_SUPERVISED"] = "1"
        childEnvironment["JRBAR_SUPERVISOR_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        if let environment { childEnvironment.merge(environment) { _, new in new } }
        process.environment = childEnvironment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        lock.lock()
        generation += 1
        let myGeneration = generation
        lock.unlock()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, stream: "stdout")
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, stream: "stderr")
        }
        process.terminationHandler = { [weak self] finished in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            self?.consume(stdout.fileHandleForReading.readDataToEndOfFile(), stream: "stdout")
            self?.consume(stderr.fileHandleForReading.readDataToEndOfFile(), stream: "stderr")
            self?.childExited(finished, generation: myGeneration)
        }
        do {
            try process.run()
        } catch {
            onOutput?("supervisor", "cannot launch \(executable): \(error)")
            recordFailure()
            return
        }
        lock.lock()
        self.process = process
        lock.unlock()
        onOutput?("supervisor", "core started (pid \(process.processIdentifier))")
        setState(.running(pid: process.processIdentifier))
    }

    private func childExited(_ process: Process, generation: Int) {
        let signal: Int32? = process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil
        let exit = Exit(at: Date(), status: process.terminationStatus, signal: signal)
        onExit?(exit)
        lock.lock()
        let current = self.generation == generation
        let stopping = self.stopping
        if current { self.process = nil }
        lock.unlock()
        if let signal {
            onOutput?("supervisor", "core exited on signal \(signal)")
        } else {
            onOutput?("supervisor", "core exited with status \(process.terminationStatus)")
        }
        guard current, !stopping else { return }
        recordFailure()
    }

    private func recordFailure() {
        lock.lock()
        exits.append(Date())
        let recent = prunedExits()
        exits = recent
        let failures = recent.count
        if failures >= maxFailures {
            lock.unlock()
            onOutput?("supervisor", "core crashed \(failures) times in \(Int(failureWindow)) s; giving up")
            setState(.crashed(failures: failures))
            return
        }
        let delay = CoreBackoff.delay(afterFailures: failures) * backoffScale
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let cancelled = self.stopping || self.process != nil
            self.restartTimer = nil
            self.lock.unlock()
            if !cancelled { self.spawn() }
        }
        restartTimer?.cancel()
        restartTimer = work
        lock.unlock()
        setState(.backingOff(failures: failures, delay: delay))
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func prunedExits() -> [Date] {
        let cutoff = Date(timeIntervalSinceNow: -failureWindow)
        return exits.filter { $0 >= cutoff }
    }

    private func setState(_ new: State) {
        lock.lock()
        let changed = _state != new
        _state = new
        lock.unlock()
        if changed { onStateChange?(new) }
    }

    // MARK: Output

    private func consume(_ data: Data, stream: String) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        var buffer = (stream == "stdout" ? stdoutRemainder : stderrRemainder) + text
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[..<newline]))
            buffer = String(buffer[buffer.index(after: newline)...])
        }
        if stream == "stdout" { stdoutRemainder = buffer } else { stderrRemainder = buffer }
        lock.unlock()
        for line in lines where !line.isEmpty { onOutput?(stream, line) }
    }
}
