import CryptoKit
import Darwin
import Foundation
import Security

/// The per-launch secret that makes this app the only client the daemon takes
/// privileged commands from (docs/CORE-PROTOCOL.md, "Who may send what").
///
/// `CoreSupervisor` makes a fresh one every time it starts the daemon and
/// hands it over the child's stdin pipe, never its environment or arguments.
/// This object is where the app keeps its own copy, in memory only: nothing
/// writes it to disk, a log or a defaults key. The client reads it when a
/// connection says hello and proves it with an HMAC; the secret itself never
/// crosses the socket.
public final class CoreAuthSecret: @unchecked Sendable {
    public static let byteCount = 32

    private let lock = NSLock()
    private var secret: Data?
    private var daemonPID: Int32?

    public init() {}

    /// The secret of the daemon the app started most recently, if any.
    public var current: Data? {
        lock.lock(); defer { lock.unlock() }
        return secret
    }

    /// The pid of that daemon while it runs: a proof is sent only to it.
    public var supervisedPID: Int32? {
        lock.lock(); defer { lock.unlock() }
        return daemonPID
    }

    /// Records the secret of a daemon about to start (`pid` nil), or clears
    /// both (`new` nil).
    public func set(_ new: Data?, daemonPID pid: Int32? = nil) {
        lock.lock()
        secret = new
        daemonPID = pid
        lock.unlock()
    }

    /// Records the pid of the daemon the current secret belongs to.
    public func setDaemonPID(_ pid: Int32?) {
        lock.lock()
        daemonPID = pid
        lock.unlock()
    }

    /// 32 bytes from the system's secure random source, or nil if it fails.
    public static func generate() -> Data? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return status == errSecSuccess ? Data(bytes) : nil
    }

    /// `HMAC-SHA256(secret, "jrbar-core-auth-v1\n" + nonce)` as lowercase hex,
    /// the proof the daemon's `auth` command checks.
    public static func proof(secret: Data, nonce: String) -> String {
        var message = Data("jrbar-core-auth-v1\n".utf8)
        message.append(Data(nonce.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        return code.map { String(format: "%02x", $0) }.joined()
    }
}

/// Why a connection to the daemon is not authenticated, in the words the app
/// can log and show.
public enum CoreAuthRefusal: Equatable, Sendable {
    /// The daemon this app started offered no challenge, so it did not take
    /// the secret (it was an older build, or the hand-off failed).
    case daemonOffersNoChallenge
    /// The process on the socket is not the daemon this app started: a daemon
    /// from an earlier run still shutting down, one started by hand or by a
    /// LaunchAgent, or something else that took the path.
    case peerIsNotOurDaemon
    /// The daemon answered the proof with a refusal (its code).
    case proofRejected(String)
    /// The daemon did not answer the proof in time.
    case noReply

    public var sentence: String {
        switch self {
        case .daemonOffersNoChallenge:
            return "The daemon JR-Bar started did not take its secret, so it will not take changes from JR-Bar."
        case .peerIsNotOurDaemon:
            return "Another daemon is answering on JR-Bar's socket, not the one JR-Bar started, so JR-Bar "
                + "did not send it its proof and its changes will be refused. Quit the other daemon or restart JR-Bar."
        case .proofRejected:
            return "The daemon did not accept JR-Bar's proof, so it will not take changes from it."
        case .noReply:
            return "The daemon did not answer JR-Bar's proof in time."
        }
    }
}

enum CoreSocketPeer {
    /// The pid of the process on the other end of a connected Unix socket.
    static func pid(of socket: Int32) -> Int32? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        // SOL_LOCAL = 0, LOCAL_PEERPID = 2 on macOS.
        guard getsockopt(socket, 0, 2, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// The parent of `pid`, for a daemon started through a wrapper that did
    /// not exec.
    static func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    /// Whether the peer is the daemon the app started, or a direct child of it.
    static func isSupervised(peer: Int32?, supervised: Int32?,
                             parentOf: (Int32) -> Int32? = CoreSocketPeer.parent(of:)) -> Bool {
        guard let peer, let supervised else { return false }
        if peer == supervised { return true }
        return parentOf(peer) == supervised
    }
}
