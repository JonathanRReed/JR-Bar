import Darwin
import Foundation

@MainActor
protocol DockShortcutsReading: AnyObject {
    @discardableResult
    func execute(_ arguments: [String], completion: @escaping @MainActor (DockShortcutsResult) -> Void) -> () -> Void
}

enum DockShortcutsResult: Equatable, Sendable {
    case success(String), failed, timedOut
}

/// Direct argv only. Output is bounded, stdin is closed, and every child has a deadline.
@MainActor
final class DockShortcutsReader: DockShortcutsReading {
    private let executable: String
    private let timeout: TimeInterval

    init(executable: String = "/usr/bin/shortcuts", timeout: TimeInterval = 10) {
        self.executable = executable
        self.timeout = timeout
    }

    func execute(_ arguments: [String], completion: @escaping @MainActor (DockShortcutsResult) -> Void) -> () -> Void {
        let job = Job(executable: executable, arguments: arguments, timeout: timeout)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = job.run()
            _ = Task { @MainActor in completion(result) }
        }
        return { job.cancel() }
    }

    private final class Job: @unchecked Sendable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval
        let lock = NSLock()
        var pid: pid_t = 0
        var cancelled = false

        init(executable: String, arguments: [String], timeout: TimeInterval) {
            self.executable = executable
            self.arguments = arguments
            self.timeout = timeout
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
            }
        }

        func run() -> DockShortcutsResult {
            var descriptors: [Int32] = [0, 0]
            guard Darwin.pipe(&descriptors) == 0 else { return .failed }
            let readFD = descriptors[0], writeFD = descriptors[1]
            defer { Darwin.close(readFD) }
            guard fcntl(readFD, F_SETFL, O_NONBLOCK) == 0 else {
                Darwin.close(writeFD)
                return .failed
            }
            var actions: posix_spawn_file_actions_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else {
                Darwin.close(writeFD)
                return .failed
            }
            defer { posix_spawn_file_actions_destroy(&actions) }
            var attributes: posix_spawnattr_t?
            guard posix_spawnattr_init(&attributes) == 0 else {
                Darwin.close(writeFD)
                return .failed
            }
            defer { posix_spawnattr_destroy(&attributes) }
            let setup = [
                posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)),
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO),
                posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
                posix_spawn_file_actions_addclose(&actions, readFD),
                posix_spawn_file_actions_addclose(&actions, writeFD),
            ]
            guard setup.allSatisfy({ $0 == 0 }), !arguments.contains(where: { $0.utf8.contains(0) }) else {
                Darwin.close(writeFD)
                return .failed
            }
            let strings = ([executable] + arguments).map { strdup($0) }
            defer { for string in strings { free(string) } }
            var argv = strings + [nil]
            let launched = lock.withLock {
                guard !cancelled else { return false }
                return argv.withUnsafeMutableBufferPointer {
                    posix_spawn(&pid, executable, &actions, &attributes, $0.baseAddress!, environ) == 0
                }
            }
            Darwin.close(writeFD)
            guard launched else { return .failed }
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            var status: Int32 = 0
            var timedOut = false
            var overflow = false
            var waitFailed = false
            while true {
                for _ in 0..<16 {
                    let count = Darwin.read(readFD, &buffer, buffer.count)
                    guard count > 0 else { break }
                    if arguments.first != "list" { continue }
                    if output.count + count <= 256 * 1024 { output.append(contentsOf: buffer.prefix(count)) }
                    else { overflow = true }
                }
                let finished: Bool = lock.withLock {
                    let result = waitpid(pid, &status, WNOHANG)
                    if result == pid { pid = 0; return true }
                    if result < 0 && errno != EINTR { waitFailed = true; pid = 0; return true }
                    if !timedOut && ProcessInfo.processInfo.systemUptime >= deadline {
                        timedOut = true
                        _ = Darwin.kill(pid, SIGKILL)
                    }
                    return false
                }
                if finished {
                    // Drain the final pipe bytes after exit without waiting on descendants.
                    for _ in 0..<64 {
                        let count = Darwin.read(readFD, &buffer, buffer.count)
                        guard count > 0 else { break }
                        if arguments.first != "list" { continue }
                        if output.count + count <= 256 * 1024 { output.append(contentsOf: buffer.prefix(count)) }
                        else { overflow = true }
                    }
                    break
                }
                var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
                _ = Darwin.poll(&descriptor, 1, 50)
            }
            if timedOut { return .timedOut }
            guard !lock.withLock({ cancelled }), !overflow, !waitFailed, status == 0,
                  let text = String(data: output, encoding: .utf8) else { return .failed }
            return .success(text)
        }
    }
}
