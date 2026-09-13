import Darwin
import Foundation
import Testing
@testable import JRBarCore

/// A loopback Unix socket that accepts connections and optionally speaks
/// the greeting, for exercising CoreClient's deadlines against a daemon
/// that misbehaves in specific ways.
@Suite("Core client deadlines", .serialized)
struct CoreClientTests {
    final class StubCoreSocket: @unchecked Sendable {
        let path: String
        let speakHello: Bool
        private let lock = NSLock()
        private var listenFD: Int32 = -1
        private var clients: [Int32] = []
        private var running = false

        init(path: String, speakHello: Bool) {
            self.path = path
            self.speakHello = speakHello
        }

        func start() throws {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            precondition(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard listenFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            unlink(path)
            let length = socklen_t(MemoryLayout<sa_family_t>.size + MemoryLayout<UInt8>.size + bytes.count + 1)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listenFD, $0, length)
                }
            }
            guard bound == 0, Darwin.listen(listenFD, 4) == 0 else {
                let code = errno
                close(listenFD)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            lock.lock(); running = true; lock.unlock()
            Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        }

        var acceptCount: Int {
            lock.lock(); defer { lock.unlock() }
            return clients.count
        }

        private func acceptLoop() {
            while true {
                let descriptor = accept(listenFD, nil, nil)
                guard descriptor >= 0 else { return }
                lock.lock()
                guard running else { lock.unlock(); close(descriptor); return }
                clients.append(descriptor)
                let greet = speakHello
                lock.unlock()
                if greet {
                    var nosig: Int32 = 1
                    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
                    let hello = "{\"t\":\"hello\",\"v\":1,\"core_version\":\"stub\",\"pid\":1,\"capabilities\":[]}\n"
                    _ = hello.withCString { Darwin.write(descriptor, $0, strlen($0)) }
                }
                // Never read and never write again: the peer is wedged.
            }
        }

        func stop() {
            lock.lock()
            running = false
            let fds = clients
            clients = []
            let listener = listenFD
            listenFD = -1
            lock.unlock()
            if listener >= 0 {
                shutdown(listener, SHUT_RDWR)
                close(listener)
            }
            for descriptor in fds { close(descriptor) }
            unlink(path)
        }
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [CoreClient.Event] = []
        var events: [CoreClient.Event] { lock.lock(); defer { lock.unlock() }; return _events }
        func add(_ event: CoreClient.Event) { lock.lock(); _events.append(event); lock.unlock() }
        var connectAttempts: Int {
            events.reduce(0) { count, event in
                if case .connecting = event { return count + 1 }
                return count
            }
        }
        var disconnectReasons: [String] {
            events.compactMap { event in
                if case .disconnected(let reason) = event { return reason }
                return nil
            }
        }
    }

    static func temporarySocketPath() -> String {
        let name = "jrbar-client-test-\(UUID().uuidString.prefix(8)).sock"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    static func wait(timeout: TimeInterval = 10, until condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return condition()
    }

    @Test("a daemon that accepts but never speaks is dropped at the hello deadline, then retried")
    func silentDaemonDropsAtHelloDeadline() async throws {
        let path = Self.temporarySocketPath()
        let server = StubCoreSocket(path: path, speakHello: false)
        try server.start()
        defer { server.stop() }

        let events = EventLog()
        let client = CoreClient(socketPath: path, replyTimeout: 1,
                                helloTimeout: 0.3, connectTimeout: 1) { events.add($0) }
        client.start()
        defer { client.stop() }

        #expect(await Self.wait { !events.disconnectReasons.isEmpty },
                "a silent daemon must be disconnected at the hello deadline")
        #expect(events.disconnectReasons.contains { $0.contains("no hello") },
                "reasons were \(events.disconnectReasons)")
        // The disconnect is a reconnect, not a park.
        #expect(await Self.wait { events.connectAttempts >= 2 })
        #expect(await Self.wait { server.acceptCount >= 2 },
                "the client must keep retrying the socket")
    }

    @Test("send throws at its deadline even while the write is still blocked")
    func sendIsBoundedWhileWriteBlocked() async throws {
        let path = Self.temporarySocketPath()
        let server = StubCoreSocket(path: path, speakHello: true)
        try server.start()
        defer { server.stop() }

        let events = EventLog()
        let client = CoreClient(socketPath: path, replyTimeout: 0.4,
                                helloTimeout: 2, connectTimeout: 1,
                                writeTimeout: 5) { events.add($0) }
        client.start()
        defer { client.stop() }
        #expect(await Self.wait { client.isConnected })

        // Larger than any socket buffer: writeAll cannot drain it while
        // the peer never reads. The armed-before-write deadline must fire.
        let blob = String(repeating: "x", count: 8 * 1024 * 1024)
        let started = Date()
        do {
            _ = try await client.send(name: "fill",
                                      args: ["blob": .string(blob)],
                                      timeout: 0.4)
            Issue.record("send to a never-reading daemon should throw")
        } catch let error as CoreClientError {
            switch error {
            case .timeout, .writeFailed:
                break
            default:
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(Date().timeIntervalSince(started) < 4,
                "send stayed blocked on a peer that never reads")
        // The wedged connection is dropped, not parked.
        #expect(await Self.wait { !events.disconnectReasons.isEmpty })
    }
}
