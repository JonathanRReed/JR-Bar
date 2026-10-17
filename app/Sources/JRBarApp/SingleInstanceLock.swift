import Foundation
import JRBarCore

/// One live JR-Bar per state directory. A second instance — the
/// `/Applications` copy beside `~/Applications`, `open -n`, or a dev
/// binary sharing this state — draws a second Screen Bar, island, and
/// set of menu-bar covers over the first's, which reads on screen as
/// doubled bands and ghost surfaces. The guard is an exclusive advisory
/// `flock` on `<state>/app.lock` held for the process's life: whoever
/// cannot take it yields. The kernel releases it when the holder dies,
/// so a crashed instance never wedges the next launch.
///
/// It yields only for proven contention. An app that cannot open or lock
/// the file at all (an unwritable state directory, a filesystem without
/// `flock`) has no other instance to defer to, and quitting would leave
/// an accessory app with no icon and no word on why, so it runs without
/// the lock and says so.
enum SingleInstanceLock {
    /// What the holder wrote into the lock file: the lock itself is the
    /// kernel's, the words are only a courtesy that tells a newcomer
    /// whether to wait or to go.
    enum HolderState: Equatable {
        /// A live instance, up and staying.
        case running
        /// An instance that is quitting: it has released its surfaces and
        /// is waiting on the daemon (up to three seconds) before the
        /// process ends. The lock is its last thing to go.
        case quitting
        /// Nothing written: a build from before the courtesy, or a file
        /// no one has filled.
        case unknown
    }

    /// How long a newcomer waits for a holder that is on its way out. The
    /// person who quits JR-Bar and opens it again at once must find an
    /// icon, not a second instance that yields to a dying first and
    /// leaves nobody on the bar.
    struct Wait {
        /// For a holder that says it is quitting: the daemon's grace is
        /// three seconds, so ten is the margin.
        var quitting: TimeInterval = 10
        /// For a holder that says nothing (an older build quitting): a
        /// bit longer than the daemon's grace.
        var unknown: TimeInterval = 4
        var poll: TimeInterval = 0.1
        /// Replaceable so a test passes a clock instead of waiting.
        var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

        /// No waiting: contention yields at once.
        static var none: Wait { Wait(quitting: 0, unknown: 0) }
        /// The launch's: wait out a predecessor that is quitting.
        static var launch: Wait { Wait() }
    }

    /// The fd holding the lock, or nil only when another live instance
    /// has it and this process must yield. `-1` answers "no lock held":
    /// the `JRBAR_ALLOW_MULTI=1` dev bypass, or no lock could be taken
    /// here (`onUnavailable` is told the errno first). Callers therefore
    /// branch only on nil. A real fd stays open for the app's life —
    /// never closed, so the lock can never be dropped early — until a
    /// quit hands it back (`release`).
    static func acquire(stateDirectory: String = CoreSocketPath.stateDirectory(),
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        wait: Wait = .none,
                        onUnavailable: (Int32) -> Void = { _ in }) -> Int32? {
        if environment["JRBAR_ALLOW_MULTI"] == "1" { return -1 }
        try? FileManager.default.createDirectory(atPath: stateDirectory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let path = stateDirectory + "/app.lock"
        // O_CLOEXEC: a spawned daemon or helper must not inherit the
        // fd and keep the lock alive past the app's own death.
        var fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if fd < 0 {
            let openError = errno
            // A lock file a sudo run left root-owned is still readable, and
            // `flock` needs no write access, so the guard can still hold.
            if openError == EACCES || openError == EPERM {
                fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fd >= 0 else {
                onUnavailable(openError)
                return -1
            }
        }
        var waited: TimeInterval = 0
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                write(.running, to: fd)
                return fd
            }
            // Read errno before anything can overwrite it.
            let lockError = errno
            guard lockError == EWOULDBLOCK else {
                close(fd)
                onUnavailable(lockError)
                return -1
            }
            // EWOULDBLOCK (EAGAIN on Darwin) is another live holder: the
            // one case that yields — after a wait, when the holder says
            // it is on its way out.
            let limit: TimeInterval
            switch holderState(stateDirectory: stateDirectory) {
            case .running: limit = 0
            case .quitting: limit = wait.quitting
            case .unknown: limit = wait.unknown
            }
            guard waited < limit else {
                close(fd)
                return nil
            }
            wait.sleep(wait.poll)
            waited += max(wait.poll, 0.001)
        }
    }

    /// What the current holder wrote, for a newcomer deciding whether to
    /// wait. Readable without the lock.
    static func holderState(stateDirectory: String = CoreSocketPath.stateDirectory()) -> HolderState {
        let text = (try? String(contentsOfFile: stateDirectory + "/app.lock", encoding: .utf8)) ?? ""
        if text.hasPrefix("quitting") { return .quitting }
        if text.hasPrefix("running") { return .running }
        return .unknown
    }

    /// The holder says it is quitting — written first thing in the quit,
    /// before the slow part, so a relaunch inside the daemon's grace waits
    /// for the lock instead of yielding to a process that is about to go.
    static func markQuitting(_ fd: Int32) {
        write(.quitting, to: fd)
    }

    private static func write(_ state: HolderState, to fd: Int32) {
        guard fd >= 0 else { return }
        let word = state == .quitting ? "quitting" : "running"
        let line = "\(word) \(ProcessInfo.processInfo.processIdentifier)\n"
        // A read-only fallback fd cannot write; the lock still holds.
        guard ftruncate(fd, 0) == 0 else { return }
        _ = line.withCString { pwrite(fd, $0, strlen($0), 0) }
    }

    /// Drops the lock by closing its fd. The app does it once at the very
    /// end of a quit, after everything it owned is stopped; tests do it
    /// to free a state directory.
    static func release(_ fd: Int32) {
        if fd >= 0 { close(fd) }
    }
}
