import Darwin
import Foundation
import Testing
@testable import JRBarCore

/// The app's side of "Who may send what" (docs/CORE-PROTOCOL.md): the secret,
/// its hand-off to the daemon it starts, and the client's `auth` exchange
/// against a stand-in daemon on a temporary socket. Synthetic data only.
@Suite("Core socket authentication", .serialized)
struct CoreAuthTests {
    static let vectorSecret = Data((0..<32).map { UInt8($0) })

    static func wait(timeout: TimeInterval = 10, until condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return condition()
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    // MARK: The secret

    @Test("the proof is the HMAC the Python daemon computes")
    func proofMatchesTheDaemonsVectors() {
        // Computed by src/jrbar/core_auth.py: auth_proof(bytes(range(32)), nonce).
        #expect(CoreAuthSecret.proof(secret: Self.vectorSecret, nonce: "0123456789abcdef0123456789abcdef")
                == "d5d8f3d812a133112bcf08ac65d2376f39ed34dcd5440332119b760c426ceb28")
        #expect(CoreAuthSecret.proof(secret: Data(count: 32), nonce: String(repeating: "f", count: 32))
                == "68ee0043f9199b7d360f28ff794c967513d7ee7694d940edc6050f7da79c835e")
    }

    @Test("a generated secret is 32 bytes and never repeats")
    func generatedSecretsAreFreshAndFull() throws {
        let first = try #require(CoreAuthSecret.generate())
        let second = try #require(CoreAuthSecret.generate())
        #expect(first.count == CoreAuthSecret.byteCount)
        #expect(second.count == CoreAuthSecret.byteCount)
        #expect(first != second)
    }

    @Test("the holder keeps the secret and the daemon's pid, and clears both")
    func holderKeepsAndClears() {
        let holder = CoreAuthSecret()
        #expect(holder.current == nil && holder.supervisedPID == nil)
        holder.set(Self.vectorSecret)
        holder.setDaemonPID(42)
        #expect(holder.current == Self.vectorSecret && holder.supervisedPID == 42)
        holder.set(nil)
        #expect(holder.current == nil && holder.supervisedPID == nil)
    }

    @Test("a peer is ours when it is the supervised pid or its direct child")
    func peerRule() {
        let parents: [Int32: Int32] = [200: 100, 300: 1]
        let parentOf: (Int32) -> Int32? = { parents[$0] }
        #expect(CoreSocketPeer.isSupervised(peer: 100, supervised: 100, parentOf: parentOf))
        #expect(CoreSocketPeer.isSupervised(peer: 200, supervised: 100, parentOf: parentOf), "a wrapper that did not exec")
        #expect(!CoreSocketPeer.isSupervised(peer: 300, supervised: 100, parentOf: parentOf))
        #expect(!CoreSocketPeer.isSupervised(peer: nil, supervised: 100, parentOf: parentOf))
        #expect(!CoreSocketPeer.isSupervised(peer: 100, supervised: nil, parentOf: parentOf))
    }

    @Test("this process is its own peer through the real socket calls")
    func realPeerPid() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        #expect(CoreSocketPeer.pid(of: pair[0]) == getpid())
        #expect(CoreSocketPeer.parent(of: getpid()) == getppid())
    }

    // MARK: The hand-off to the daemon

    @Test("the hand-off pipe carries the secret then end-of-file, and no other child inherits it")
    func handoffPipe() throws {
        let secret = try #require(CoreAuthSecret.generate())
        let pipe = try #require(CoreSupervisor.makeHandoffPipe(carrying: secret))
        let reading = pipe.fileHandleForReading
        let flags = fcntl(reading.fileDescriptor, F_GETFD)
        #expect(flags >= 0 && flags & FD_CLOEXEC != 0, "the read end is close-on-exec here")
        #expect(try reading.read(upToCount: 64) == secret)
        #expect(try reading.read(upToCount: 64) == nil || (try reading.read(upToCount: 64))?.isEmpty == true,
                "then end-of-file: the write end is closed")
        try reading.close()
    }

    /// The child's report: the 32 bytes it read from stdin, whether the secret
    /// is in its environment or its own argument list, and what it was told.
    private static let reportScript = """
    HEX=$(dd bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \\n')
    ENVHITS=$(env | grep -cF "$HEX")
    ARGHITS=$(ps -o args= -p $$ | grep -cF "$HEX")
    echo "secret=$HEX"
    echo "envhits=$ENVHITS"
    echo "arghits=$ARGHITS"
    echo "announced=${JRBAR_AUTH_STDIN:-none}"
    echo ready
    while :; do sleep 0.05; done
    """

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        func add(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
        func values(_ key: String) -> [String] {
            lines.compactMap { $0.hasPrefix("stdout: \(key)=") ? String($0.dropFirst("stdout: \(key)=".count)) : nil }
        }
        var readyCount: Int { lines.filter { $0 == "stdout: ready" }.count }
    }

    @Test("a supervised child reads the app's secret on stdin; it is in no environment or argument")
    func childReceivesTheSecretOnlyOnStdin() async throws {
        let holder = CoreAuthSecret()
        let log = Lines()
        let supervisor = CoreSupervisor(executable: "/bin/sh", arguments: ["-c", Self.reportScript],
                                        backoffScale: 0.02, authSecret: holder)
        supervisor.onOutput = { stream, line in log.add("\(stream): \(line)") }
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0.3) }
        #expect(await Self.wait { log.readyCount >= 1 }, "\(log.lines)")

        let secret = try #require(holder.current)
        #expect(secret.count == 32)
        #expect(log.values("secret") == [Self.hex(secret)], "the child read exactly the app's secret")
        #expect(log.values("envhits") == ["0"], "the secret is in no environment variable")
        #expect(log.values("arghits") == ["0"], "the secret is in no argument list")
        #expect(log.values("announced") == ["1"], "the variable names the channel and carries no secret")
        guard case .running(let pid) = supervisor.state else { Issue.record("not running"); return }
        #expect(holder.supervisedPID == pid)

        supervisor.stop(gracePeriod: 0.3)
        #expect(holder.current == nil && holder.supervisedPID == nil, "a stopped supervisor holds no secret")
    }

    @Test("every start of the daemon makes a new secret and hands over the new one")
    func eachStartMakesANewSecret() async throws {
        let holder = CoreAuthSecret()
        let log = Lines()
        let supervisor = CoreSupervisor(executable: "/bin/sh", arguments: ["-c", Self.reportScript],
                                        backoffScale: 0.02, authSecret: holder)
        supervisor.onOutput = { stream, line in log.add("\(stream): \(line)") }
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0.3) }
        #expect(await Self.wait { log.readyCount >= 1 })
        let first = try #require(holder.current)

        supervisor.restart()
        #expect(await Self.wait { log.readyCount >= 2 }, "\(log.lines)")
        let second = try #require(holder.current)
        #expect(first != second)
        #expect(log.values("secret") == [Self.hex(first), Self.hex(second)])
    }

    @Test("a supervisor with no holder gives the child /dev/null and no announcement")
    func noHolderNoHandoff() async {
        let log = Lines()
        let script = """
        echo "bytes=$(dd bs=32 count=1 2>/dev/null | wc -c | tr -d ' ')"
        echo "announced=${JRBAR_AUTH_STDIN:-none}"
        echo ready
        while :; do sleep 0.05; done
        """
        let supervisor = CoreSupervisor(executable: "/bin/sh", arguments: ["-c", script], backoffScale: 0.02)
        supervisor.onOutput = { stream, line in log.add("\(stream): \(line)") }
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0.3) }
        #expect(await Self.wait { log.readyCount >= 1 })
        #expect(log.values("bytes") == ["0"])
        #expect(log.values("announced") == ["none"])
    }

    @Test("when no secret can be made, the child is told nothing and the holder stays empty")
    func noRandomnessNoSecret() async {
        let holder = CoreAuthSecret()
        let log = Lines()
        let script = """
        echo "announced=${JRBAR_AUTH_STDIN:-none}"
        echo ready
        while :; do sleep 0.05; done
        """
        let supervisor = CoreSupervisor(executable: "/bin/sh", arguments: ["-c", script],
                                        backoffScale: 0.02, authSecret: holder)
        supervisor.secretGenerator = { nil }
        supervisor.onOutput = { stream, line in log.add("\(stream): \(line)") }
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0.3) }
        #expect(await Self.wait { log.readyCount >= 1 })
        #expect(log.values("announced") == ["none"])
        #expect(holder.current == nil)
        #expect(log.lines.contains { $0.contains("could not make an app secret") })
    }

    // MARK: The client's exchange, against a stand-in daemon

    /// A daemon on a temporary Unix socket that speaks hello (with or without a
    /// nonce), checks `auth` proofs the way the real one does, refuses
    /// `answer_ask` with `unauthenticated` until a proof was accepted, and
    /// records every command it read, in order.
    final class AuthStubCore: @unchecked Sendable {
        let path: String
        /// The secret each accepted connection expects, in accept order (the last repeats).
        var expectedSecrets: [Data?]
        /// Whether hello carries a nonce.
        var offersChallenge = true
        /// Held until signalled when set: the hello waits for it.
        var helloGate: DispatchSemaphore?
        private let lock = NSLock()
        private var listenFD: Int32 = -1
        private var accepted = 0
        private var _commands: [String] = []
        private var _closedAfterBadProof = 0

        init(path: String, expectedSecrets: [Data?]) {
            self.path = path
            self.expectedSecrets = expectedSecrets
        }

        var commands: [String] { lock.lock(); defer { lock.unlock() }; return _commands }
        var closedAfterBadProof: Int { lock.lock(); defer { lock.unlock() }; return _closedAfterBadProof }
        var acceptCount: Int { lock.lock(); defer { lock.unlock() }; return accepted }

        func start() throws {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard listenFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            unlink(path)
            let length = socklen_t(MemoryLayout<sa_family_t>.size + MemoryLayout<UInt8>.size + bytes.count + 1)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFD, $0, length) }
            }
            guard bound == 0, Darwin.listen(listenFD, 4) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let listener = listenFD
            Thread.detachNewThread { [weak self] in
                while true {
                    let descriptor = accept(listener, nil, nil)
                    guard descriptor >= 0, let self else { return }
                    self.lock.lock()
                    let index = self.accepted
                    self.accepted += 1
                    self.lock.unlock()
                    Thread.detachNewThread { [weak self] in self?.serve(descriptor, index: index) }
                }
            }
        }

        func stop() {
            let listener = listenFD
            listenFD = -1
            if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener) }
            unlink(path)
        }

        private func write(_ descriptor: Int32, _ text: String) {
            _ = text.withCString { Darwin.write(descriptor, $0, strlen($0)) }
        }

        private func serve(_ descriptor: Int32, index: Int) {
            var nosig: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
            defer { close(descriptor) }
            helloGate?.wait()
            lock.lock()
            let expected = expectedSecrets.isEmpty ? nil : expectedSecrets[min(index, expectedSecrets.count - 1)]
            let challenge = offersChallenge && expected != nil
            lock.unlock()
            let nonce = String(format: "%032x", index + 1)
            let auth = challenge ? ",\"auth\":{\"scheme\":\"hmac-sha256\",\"nonce\":\"\(nonce)\"}" : ""
            write(descriptor, "{\"t\":\"hello\",\"v\":1,\"core_version\":\"stub\",\"pid\":\(getpid()),\"capabilities\":[]\(auth)}\n")
            var authenticated = false
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(descriptor, &chunk, chunk.count)
                if count <= 0 { return }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let name = object["name"] as? String, let id = object["id"] as? String else { continue }
                    lock.lock(); _commands.append(name); lock.unlock()
                    if name == "auth" {
                        let proof = ((object["args"] as? [String: Any])?["proof"] as? String) ?? ""
                        if let expected, challenge,
                           proof == CoreAuthSecret.proof(secret: expected, nonce: nonce) {
                            authenticated = true
                            write(descriptor, "{\"t\":\"reply\",\"v\":1,\"id\":\"\(id)\",\"ok\":true,\"result\":{\"authenticated\":true}}\n")
                        } else {
                            write(descriptor, "{\"t\":\"reply\",\"v\":1,\"id\":\"\(id)\",\"ok\":false,\"error\":{\"code\":\"auth_failed\",\"message\":\"the proof did not match\"}}\n")
                            lock.lock(); _closedAfterBadProof += 1; lock.unlock()
                            return
                        }
                    } else if authenticated || name == "ping" {
                        write(descriptor, "{\"t\":\"reply\",\"v\":1,\"id\":\"\(id)\",\"ok\":true,\"result\":{\"ran\":\"\(name)\"}}\n")
                    } else {
                        write(descriptor, "{\"t\":\"reply\",\"v\":1,\"id\":\"\(id)\",\"ok\":false,\"error\":{\"code\":\"unauthenticated\",\"message\":\"That change has to be made in JR-Bar itself: open JR-Bar and use Settings.\"}}\n")
                    }
                }
            }
        }
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [CoreClient.Event] = []
        var events: [CoreClient.Event] { lock.lock(); defer { lock.unlock() }; return _events }
        func add(_ event: CoreClient.Event) { lock.lock(); _events.append(event); lock.unlock() }
        var authenticatedCount: Int { events.filter { if case .authenticated = $0 { return true }; return false }.count }
        var refusals: [CoreAuthRefusal] {
            events.compactMap { if case .authRefused(let reason) = $0 { return reason }; return nil }
        }
    }

    static func temporarySocketPath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("jrbar-auth-test-\(UUID().uuidString.prefix(8)).sock")
    }

    private func holder(secret: Data?, pid: Int32? = getpid()) -> CoreAuthSecret {
        let holder = CoreAuthSecret()
        if let secret { holder.set(secret, daemonPID: pid) }
        return holder
    }

    @Test("the client proves the secret, and its first command follows the proof")
    func clientAuthenticatesBeforeItSendsAnything() async throws {
        let path = Self.temporarySocketPath()
        let stub = AuthStubCore(path: path, expectedSecrets: [Self.vectorSecret])
        try stub.start()
        defer { stub.stop() }
        let events = EventLog()
        let client = CoreClient(socketPath: path, helloTimeout: 2, connectTimeout: 2,
                                auth: holder(secret: Self.vectorSecret)) { events.add($0) }
        client.start()
        defer { client.stop() }
        #expect(await Self.wait { client.isConnected })

        let reply = try await client.send(name: "answer_ask", args: ["session": .string("claude:synthetic")])

        #expect(reply.ok, "\(String(describing: reply.error))")
        #expect(events.authenticatedCount == 1 && client.isAuthenticated)
        #expect(stub.commands == ["auth", "answer_ask"], "the proof is the first command on the wire")
    }

    @Test("a command sent the moment the socket connects waits for hello and the proof")
    func commandsWaitBehindTheExchange() async throws {
        let path = Self.temporarySocketPath()
        let stub = AuthStubCore(path: path, expectedSecrets: [Self.vectorSecret])
        let gate = DispatchSemaphore(value: 0)
        stub.helloGate = gate
        try stub.start()
        defer { stub.stop() }
        let events = EventLog()
        let client = CoreClient(socketPath: path, helloTimeout: 5, connectTimeout: 2, auth: holder(secret: Self.vectorSecret)) {
            events.add($0)
        }
        client.start()
        defer { client.stop() }
        #expect(await Self.wait { client.isConnected })

        let pending = Task { try await client.send(name: "answer_ask", args: ["session": .string("claude:synthetic")]) }
        #expect(await Self.wait { stub.acceptCount == 1 })
        #expect(stub.commands.isEmpty, "nothing is written before the daemon has spoken")
        gate.signal()

        let reply = try await pending.value
        #expect(reply.ok)
        #expect(stub.commands == ["auth", "answer_ask"])
    }

    @Test("cancelling a command behind authentication does not cancel the shared exchange")
    func cancelledAuthenticationWaiterIsRetired() async throws {
        let stub = AuthStubCore(path: Self.temporarySocketPath(), expectedSecrets: [Self.vectorSecret])
        let gate = DispatchSemaphore(value: 0)
        stub.helloGate = gate
        try stub.start()
        defer { gate.signal(); stub.stop() }
        let events = EventLog()
        let client = CoreClient(socketPath: stub.path, helloTimeout: 5, connectTimeout: 2,
                                auth: holder(secret: Self.vectorSecret)) { events.add($0) }
        client.start()
        defer { client.stop() }
        try #require(await Self.wait { client.isConnected })
        let command = Task { try await client.send(name: "answer_ask") }
        try #require(await Self.wait { client.authenticationWaiterCount == 1 })
        command.cancel()
        do {
            _ = try await command.value
            Issue.record("the authentication waiter must report cancellation")
        } catch is CancellationError {}
        #expect(client.authenticationWaiterCount == 0)
        #expect(stub.commands.isEmpty)
        gate.signal()
        try #require(await Self.wait { client.isAuthenticated })
        #expect(try await client.send(name: "ping").ok)
        #expect(stub.commands == ["auth", "ping"])
    }

    @Test("a daemon that refuses the proof is reported, and the connection ends")
    func wrongSecretIsRefused() async throws {
        let path = Self.temporarySocketPath()
        let stub = AuthStubCore(path: path, expectedSecrets: [Data(repeating: 9, count: 32)])
        try stub.start()
        defer { stub.stop() }
        let events = EventLog()
        let client = CoreClient(socketPath: path, helloTimeout: 2, connectTimeout: 2,
                                auth: holder(secret: Self.vectorSecret)) { events.add($0) }
        client.start()
        defer { client.stop() }

        #expect(await Self.wait { !events.refusals.isEmpty })
        #expect(events.refusals.first == .proofRejected("auth_failed"))
        #expect(events.authenticatedCount == 0 && !client.isAuthenticated)
        #expect(stub.closedAfterBadProof >= 1)
    }

    @Test("a proof goes only to the daemon the app started")
    func proofIsWithheldFromAStranger() async throws {
        let path = Self.temporarySocketPath()
        let stub = AuthStubCore(path: path, expectedSecrets: [Self.vectorSecret])
        try stub.start()
        defer { stub.stop() }
        let events = EventLog()
        // The supervised daemon is some other process; this test process answers on the socket.
        let client = CoreClient(socketPath: path, helloTimeout: 2, connectTimeout: 2,
                                auth: holder(secret: Self.vectorSecret, pid: getpid() &+ 1)) { events.add($0) }
        client.start()
        defer { client.stop() }

        #expect(await Self.wait { !events.refusals.isEmpty })
        #expect(events.refusals.first == .peerIsNotOurDaemon)
        let reply = try await client.send(name: "answer_ask", args: [:])
        #expect(reply.error?.code == "unauthenticated")
        #expect(!stub.commands.contains("auth"), "no proof was sent")
    }

    @Test("our own daemon offering no challenge is reported, and reads still work")
    func daemonWithoutChallenge() async throws {
        let path = Self.temporarySocketPath()
        let stub = AuthStubCore(path: path, expectedSecrets: [Self.vectorSecret])
        stub.offersChallenge = false
        try stub.start()
        defer { stub.stop() }
        let events = EventLog()
        let client = CoreClient(socketPath: path, helloTimeout: 2, connectTimeout: 2,
                                auth: holder(secret: Self.vectorSecret)) { events.add($0) }
        client.start()
        defer { client.stop() }

        #expect(await Self.wait { !events.refusals.isEmpty })
        #expect(events.refusals.first == .daemonOffersNoChallenge)
        #expect(try await client.send(name: "ping").ok)
        #expect(try await client.send(name: "answer_ask").error?.code == "unauthenticated")
        #expect(!stub.commands.contains("auth"))
    }

    @Test("a client with no secret never authenticates and never waits")
    func noSecretNoExchange() async throws {
        let path = Self.temporarySocketPath()
        let stub = AuthStubCore(path: path, expectedSecrets: [nil])
        try stub.start()
        defer { stub.stop() }
        let events = EventLog()
        let client = CoreClient(socketPath: path, helloTimeout: 2, connectTimeout: 2, auth: holder(secret: nil)) {
            events.add($0)
        }
        client.start()
        defer { client.stop() }
        #expect(await Self.wait { client.isConnected })

        #expect(try await client.send(name: "ping").ok)
        #expect(events.authenticatedCount == 0 && events.refusals.isEmpty)
        #expect(stub.commands == ["ping"])
    }

    @Test("a reconnect proves the secret the supervisor holds then, not the old one")
    func reconnectUsesTheCurrentSecret() async throws {
        let path = Self.temporarySocketPath()
        let second = Data(repeating: 7, count: 32)
        let stub = AuthStubCore(path: path, expectedSecrets: [Self.vectorSecret, second])
        try stub.start()
        defer { stub.stop() }
        let secrets = holder(secret: Self.vectorSecret)
        let events = EventLog()
        let client = CoreClient(socketPath: path, helloTimeout: 2, connectTimeout: 2, auth: secrets) { events.add($0) }
        client.start()
        defer { client.stop() }
        #expect(await Self.wait { events.authenticatedCount == 1 })

        // The daemon restarts: the supervisor makes a new secret, then the socket drops.
        secrets.set(second, daemonPID: getpid())
        client.stop()
        client.start()

        #expect(await Self.wait { events.authenticatedCount == 2 }, "\(events.refusals)")
        #expect(try await client.send(name: "answer_ask").ok)
    }

    // MARK: The model

    @MainActor
    @Test("the model says why a privileged refusal happened, in words for the app's own user")
    func modelExplainsAnUnauthenticatedRefusal() {
        let model = CoreModel(socketPath: Self.temporarySocketPath())
        let refusal = CoreReply(id: "c-1", ok: false,
                                error: CoreReplyError(code: "unauthenticated", message: "That change has to be made in JR-Bar itself"))

        let before = model.explaining(refusal)
        #expect(before.error?.code == "unauthenticated")
        #expect(before.error?.message?.contains("JR-Bar itself") == false, "the app is not told to go to the app")

        model.handle(.authRefused(.peerIsNotOurDaemon))
        let after = model.explaining(refusal)
        #expect(after.error?.message == CoreAuthRefusal.peerIsNotOurDaemon.sentence)
        #expect(model.authState == .refused(CoreAuthRefusal.peerIsNotOurDaemon.sentence))

        // Other replies pass through untouched.
        let other = CoreReply(id: "c-2", ok: false, error: CoreReplyError(code: "not_found", message: "no such session"))
        #expect(model.explaining(other) == other)

        model.handle(.authenticated)
        #expect(model.authState == .authenticated)
        model.handle(.disconnected(reason: "gone"))
        #expect(model.authState == .unproven)
    }

    @MainActor
    @Test("a refusal reaches the app's handler; success resets it")
    func modelReportsRefusalsToTheApp() {
        let model = CoreModel(socketPath: Self.temporarySocketPath())
        var refused: [CoreAuthRefusal] = []
        var accepted = 0
        model.onAuthRefused = { refused.append($0) }
        model.onAuthenticated = { accepted += 1 }

        model.handle(.authRefused(.proofRejected("auth_failed")))
        model.handle(.authenticated)

        #expect(refused == [.proofRejected("auth_failed")])
        #expect(accepted == 1)
    }

    @Test("a hello with a challenge decodes, and a malformed one reads as none")
    func helloDecoding() throws {
        let good = Data(#"{"t":"hello","v":1,"auth":{"scheme":"hmac-sha256","nonce":"abc"}}"#.utf8)
        let bad = Data(#"{"t":"hello","v":1,"auth":"nope"}"#.utf8)
        let none = Data(#"{"t":"hello","v":1}"#.utf8)
        guard case .hello(let withAuth) = try CoreCodec.decode(frame: good),
              case .hello(let malformed) = try CoreCodec.decode(frame: bad),
              case .hello(let plain) = try CoreCodec.decode(frame: none) else {
            Issue.record("not a hello")
            return
        }
        #expect(withAuth.auth == CoreHelloAuth(nonce: "abc"))
        #expect(malformed.auth == nil)
        #expect(plain.auth == nil)
    }
}
