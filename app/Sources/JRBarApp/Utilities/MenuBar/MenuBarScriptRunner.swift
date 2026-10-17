import Darwin
import Foundation
import JRBarCore

/// A rule owns its shell and process group until they finish or the rule changes.
/// A live shell has no deadline. Children that create another process group are
/// outside this ownership; this is lifecycle cleanup, not a sandbox.
final class MenuBarScriptRunner: @unchecked Sendable {
    static let outputLimit = 8 * 1024
    static let jobLimit = 4

    enum Admission: Equatable, Sendable {
        case queued, ruleBusy, capacity, stopped, notScript

        var confirmation: String {
            switch self {
            case .queued: return "Script queued"
            case .ruleBusy: return "Script is already running"
            case .capacity: return "Too many scripts running"
            case .stopped: return "Menu Bar is stopped"
            case .notScript: return "Rule is not a script"
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case completed(status: Int32)
        case cancelled
        case busy
        case stopped
        case launchFailed(errno: Int32)
        case waitFailed(errno: Int32)
    }

    struct Receipt: Sendable {
        let ruleID: String
        let outcome: Outcome
        /// Never interpolate this user-controlled text into public diagnostics.
        let output: Data
    }

    enum Observation: Sendable {
        case pending, exited(status: Int32), failed(errno: Int32)
    }

    /// The child ownership boundary, injectable without changing launch behavior.
    struct ProcessDriver: Sendable {
        let observe: @Sendable (pid_t) -> Observation
        let reap: @Sendable (pid_t) -> Void
        let signalGroup: @Sendable (pid_t, Int32) -> Void

        static let system = ProcessDriver(observe: { pid in
            var info = siginfo_t()
            guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
                return errno == EINTR ? .pending : .failed(errno: errno)
            }
            guard info.si_pid == pid else { return .pending }
            let status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
            return .exited(status: status)
        }, reap: { pid in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }, signalGroup: { pid, signal in
            _ = Darwin.kill(-pid, signal)
        })
    }

    private final class Job: @unchecked Sendable {
        let rule: MenuBarTriggerRule
        var pid: pid_t = 0
        var cancelled = false
        var retiringAt: TimeInterval?
        var killed = false
        init(rule: MenuBarTriggerRule) { self.rule = rule }
    }

    private let lock = NSLock()
    private let launches: DispatchQueue
    private let report: @Sendable (Receipt) -> Void
    private let process: ProcessDriver
    private var running = false
    private var jobs: [String: Job] = [:]

    init(launches: DispatchQueue = DispatchQueue(label: "JR-Bar rule scripts"),
         process: ProcessDriver = .system,
         report: @escaping @Sendable (Receipt) -> Void) {
        self.launches = launches
        self.process = process
        self.report = report
    }

    var activeCount: Int { lock.withLock { jobs.count } }

    func start() { lock.withLock { running = true } }

    func stop() {
        lock.withLock {
            running = false
            for job in jobs.values { cancelLocked(job) }
        }
    }

    /// App quit cannot depend on a worker getting another turn for escalation.
    func shutdown() {
        lock.withLock {
            running = false
            for job in jobs.values {
                job.cancelled = true
                guard job.pid > 0, !job.killed else { continue }
                job.retiringAt = job.retiringAt ?? ProcessInfo.processInfo.systemUptime
                job.killed = true
                process.signalGroup(job.pid, SIGKILL)
            }
        }
    }

    /// Full rule equality catches trigger edits and disable as well as script edits.
    /// An explicitly run disabled rule survives an unchanged settings snapshot.
    func synchronize(_ rules: [MenuBarTriggerRule]) {
        lock.withLock {
            for job in jobs.values where !rules.contains(job.rule) { cancelLocked(job) }
        }
    }

    @discardableResult
    func submit(_ rule: MenuBarTriggerRule) -> Admission {
        guard case .runScript = rule.action else { return .notScript }
        let job = Job(rule: rule)
        let admission: Admission = lock.withLock {
            guard running else { return .stopped }
            guard jobs[rule.id] == nil else { return .ruleBusy }
            guard jobs.count < Self.jobLimit else { return .capacity }
            jobs[rule.id] = job
            return .queued
        }
        if admission != .queued {
            let outcome: Outcome = admission == .stopped ? .stopped : .busy
            report(Receipt(ruleID: rule.id, outcome: outcome, output: Data()))
            return admission
        }
        launches.async { [self] in launch(job) }
        return .queued
    }

    private func cancelLocked(_ job: Job) {
        job.cancelled = true
        retireLocked(job)
    }

    private func retireLocked(_ job: Job) {
        guard job.pid > 0, job.retiringAt == nil else { return }
        job.retiringAt = ProcessInfo.processInfo.systemUptime
        process.signalGroup(job.pid, SIGTERM)
    }

    private func launch(_ job: Job) {
        // Spawn and cancellation share admission. Stop cannot miss a just-born group.
        let result: Result<(pid_t, Int32), OutcomeError> = lock.withLock {
            guard running, !job.cancelled, jobs[job.rule.id] === job else {
                return .failure(OutcomeError(outcome: .cancelled))
            }
            guard case .runScript(let command) = job.rule.action else {
                return .failure(OutcomeError(outcome: .cancelled))
            }
            do {
                let child = try Self.spawn(command)
                job.pid = child.0
                return .success(child)
            } catch let error as OutcomeError {
                return .failure(error)
            } catch {
                return .failure(OutcomeError(outcome: .launchFailed(errno: EIO)))
            }
        }
        switch result {
        case .failure(let error): finish(job, outcome: error.outcome, output: Data())
        case .success(let child):
            let worker = Thread { [self] in drain(job, pid: child.0, fd: child.1) }
            worker.name = "JR-Bar script output"
            worker.qualityOfService = .utility
            worker.start()
        }
    }

    private struct OutcomeError: Error { let outcome: Outcome }

    private static func spawn(_ command: String) throws -> (pid_t, Int32) {
        guard !command.utf8.contains(0) else {
            throw OutcomeError(outcome: .launchFailed(errno: EINVAL))
        }
        var descriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw OutcomeError(outcome: .launchFailed(errno: errno))
        }
        let readFD = descriptors[0], writeFD = descriptors[1]
        var keepRead = false
        defer {
            Darwin.close(writeFD)
            if !keepRead { Darwin.close(readFD) }
        }
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
        guard fcntl(readFD, F_SETFL, O_NONBLOCK) == 0 else {
            throw OutcomeError(outcome: .launchFailed(errno: errno))
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let actionError = posix_spawn_file_actions_init(&actions)
        guard actionError == 0 else { throw OutcomeError(outcome: .launchFailed(errno: actionError)) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let attributeError = posix_spawnattr_init(&attributes)
        guard attributeError == 0 else { throw OutcomeError(outcome: .launchFailed(errno: attributeError)) }
        defer { posix_spawnattr_destroy(&attributes) }
        let setup = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
            posix_spawnattr_setpgroup(&attributes, 0),
        ]
        if let failure = setup.first(where: { $0 != 0 }) {
            throw OutcomeError(outcome: .launchFailed(errno: failure))
        }
        let argumentStrings: [String] = ["/bin/sh", "-c", command]
        let arguments = argumentStrings.map { argument in
            argument.withCString { strdup($0) }
        }
        defer { for argument in arguments { free(argument) } }
        var argv = arguments + [nil]
        var pid: pid_t = 0
        let error = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, "/bin/sh", &actions, &attributes, buffer.baseAddress!, environ)
        }
        guard error == 0 else { throw OutcomeError(outcome: .launchFailed(errno: error)) }
        keepRead = true
        return (pid, readFD)
    }

    static func retainTail(_ bytes: Data, in output: inout Data) {
        output.append(bytes.suffix(outputLimit))
        if output.count > outputLimit { output.removeFirst(output.count - outputLimit) }
    }

    private func drain(_ job: Job, pid: pid_t, fd: Int32) {
        var output = Data()
        var open = true
        var exitStatus: Int32?
        var waitFailure: Int32?
        defer { if open { Darwin.close(fd) } }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if open {
                // Bound each turn too: continuous output must not starve cancellation.
                for _ in 0..<16 {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count > 0 { Self.retainTail(Data(buffer.prefix(count)), in: &output) }
                    else if count == 0 {
                        Darwin.close(fd); open = false; break
                    } else if errno == EINTR { continue }
                    else if errno == EAGAIN { break }
                    else { Darwin.close(fd); open = false; break }
                }
            }
            if exitStatus == nil, waitFailure == nil {
                switch process.observe(pid) {
                case .pending: break
                case .exited(let status):
                    // Keep the leader unreaped until the last group signal.
                    exitStatus = status
                    lock.withLock { retireLocked(job) }
                case .failed(let code):
                    waitFailure = code
                    lock.withLock {
                        if waitFailure == ECHILD {
                            // Somebody already reaped it. The numeric group ID
                            // is no longer ours to signal.
                            job.pid = 0
                            job.killed = true
                            job.retiringAt = ProcessInfo.processInfo.systemUptime
                        } else { retireLocked(job) }
                    }
                }
            }
            let retirement = lock.withLock { () -> TimeInterval? in
                if job.cancelled { retireLocked(job) }
                let now = ProcessInfo.processInfo.systemUptime
                if let began = job.retiringAt, now - began >= 0.25, !job.killed {
                    job.killed = true
                    process.signalGroup(pid, SIGKILL)
                }
                return job.retiringAt
            }
            if let began = retirement,
               ProcessInfo.processInfo.systemUptime - began >= 0.5 {
                // An escaped descendant may retain stdout. Stop draining at the
                // cleanup bound; it cannot keep this job or its buffer alive.
                if open { Darwin.close(fd); open = false }
                if exitStatus != nil || waitFailure != nil { break }
            }
            var descriptor = pollfd(fd: open ? fd : -1, events: Int16(POLLIN), revents: 0)
            _ = Darwin.poll(&descriptor, 1, 50)
        }
        // No signals after this reap, even if another process inherits the PID.
        lock.withLock { job.pid = 0 }
        // ECHILD means the caller already reaped it. The number could now
        // belong to another child, so neither signal nor wait on it again.
        if waitFailure != ECHILD { process.reap(pid) }
        let cancelled = lock.withLock { job.cancelled }
        let outcome: Outcome
        if cancelled { outcome = .cancelled }
        else if let failure = waitFailure { outcome = .waitFailed(errno: failure) }
        else { outcome = .completed(status: exitStatus ?? 1) }
        finish(job, outcome: outcome, output: output)
    }

    private func finish(_ job: Job, outcome: Outcome, output: Data) {
        lock.withLock {
            if jobs[job.rule.id] === job { jobs.removeValue(forKey: job.rule.id) }
            job.pid = 0
        }
        report(Receipt(ruleID: job.rule.id, outcome: outcome, output: output))
    }
}
