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
    /// The fd holding the lock, or nil only when another live instance
    /// has it and this process must yield. `-1` answers "no lock held":
    /// the `JRBAR_ALLOW_MULTI=1` dev bypass, or no lock could be taken
    /// here (`onUnavailable` is told the errno first). Callers therefore
    /// branch only on nil. A real fd stays open for the app's life —
    /// never closed, so the lock can never be dropped early.
    static func acquire(stateDirectory: String = CoreSocketPath.stateDirectory(),
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        onUnavailable: (Int32) -> Void = { _ in }) -> Int32? {
        if environment["JRBAR_ALLOW_MULTI"] == "1" { return -1 }
        try? FileManager.default.createDirectory(atPath: stateDirectory,
                                                 withIntermediateDirectories: true)
        let path = stateDirectory + "/app.lock"
        // O_CLOEXEC: a spawned daemon or helper must not inherit the
        // fd and keep the lock alive past the app's own death.
        var fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        if fd < 0 {
            let openError = errno
            // A lock file a sudo run left root-owned is still readable, and
            // `flock` needs no write access, so the guard can still hold.
            if openError == EACCES || openError == EPERM {
                fd = open(path, O_RDONLY | O_CLOEXEC)
            }
            guard fd >= 0 else {
                onUnavailable(openError)
                return -1
            }
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            // Read errno before `close` can overwrite it.
            let lockError = errno
            close(fd)
            // EWOULDBLOCK (EAGAIN on Darwin) is another live holder: the
            // one case that yields.
            if lockError == EWOULDBLOCK { return nil }
            onUnavailable(lockError)
            return -1
        }
        return fd
    }

    /// Drops the lock by closing its fd. Only tests do this — the app's
    /// fd is held open until process death lets the kernel release it.
    static func release(_ fd: Int32) {
        if fd >= 0 { close(fd) }
    }
}
