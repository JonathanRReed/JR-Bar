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
enum SingleInstanceLock {
    /// The fd holding the lock, or nil when another live instance has
    /// it and this process must yield. `-1` answers "no lock needed"
    /// (the `JRBAR_ALLOW_MULTI=1` dev bypass) so callers only branch on
    /// nil. The fd stays open for the app's life — never closed, so the
    /// lock can never be dropped early.
    static func acquire(stateDirectory: String = CoreSocketPath.stateDirectory(),
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32? {
        if environment["JRBAR_ALLOW_MULTI"] == "1" { return -1 }
        try? FileManager.default.createDirectory(atPath: stateDirectory,
                                                 withIntermediateDirectories: true)
        // O_CLOEXEC: a spawned daemon or helper must not inherit the
        // fd and keep the lock alive past the app's own death.
        let fd = open(stateDirectory + "/app.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Drops the lock by closing its fd. Only tests do this — the app's
    /// fd is held open until process death lets the kernel release it.
    static func release(_ fd: Int32) {
        if fd >= 0 { close(fd) }
    }
}
