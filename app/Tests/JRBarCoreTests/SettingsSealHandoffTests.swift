import Foundation
import Testing
@testable import JRBarCore

/// The seal key rides the same private stdin pipe as the per-launch secret
/// (docs/CORE-PROTOCOL.md, "Protected settings"): after the secret, announced
/// by `JRBAR_AUTH_STDIN` 2 or 3, and in no environment variable or argument.
@Suite("Settings seal hand-off", .serialized)
struct SettingsSealHandoffTests {
    static let key = Data((0..<32).map { UInt8($0 &+ 150) })

    @Test("the announcement says whether anything is sealed under the key")
    func announcements() {
        #expect(CoreSupervisor.handoffAnnouncement(sealKey: nil) == "1")
        #expect(CoreSupervisor.handoffAnnouncement(sealKey: SettingsSealHandoff(key: Self.key, isNew: false)) == "2")
        #expect(CoreSupervisor.handoffAnnouncement(sealKey: SettingsSealHandoff(key: Self.key, isNew: true)) == "3")
    }

    @Test("the pipe carries the secret and then the key, then end-of-file")
    func pipeCarriesBoth() throws {
        let secret = try #require(CoreAuthSecret.generate())
        let pipe = try #require(CoreSupervisor.makeHandoffPipe(carrying: secret, sealKey: Self.key))
        let reading = pipe.fileHandleForReading

        #expect(try reading.read(upToCount: 128) == secret + Self.key)
        #expect(try reading.read(upToCount: 128)?.isEmpty ?? true)
        try reading.close()
    }

    @Test("without a key the pipe carries the secret alone, as before")
    func pipeCarriesTheSecretAlone() throws {
        let secret = try #require(CoreAuthSecret.generate())
        let pipe = try #require(CoreSupervisor.makeHandoffPipe(carrying: secret))

        #expect(try pipe.fileHandleForReading.read(upToCount: 128) == secret)
        try pipe.fileHandleForReading.close()
    }

    /// The child's report: the 64 bytes it read from stdin, whether the key is
    /// in its environment or its own arguments, and what it was told.
    private static let reportScript = """
    HEX=$(dd bs=64 count=1 2>/dev/null | od -An -tx1 | tr -d ' \\n')
    KEYHEX=$(echo "$HEX" | cut -c65-128)
    ENVHITS=$(env | grep -cF "$KEYHEX")
    ARGHITS=$(ps -o args= -p $$ | grep -cF "$KEYHEX")
    echo "bytes=$HEX"
    echo "envhits=$ENVHITS"
    echo "arghits=$ARGHITS"
    echo "announced=${JRBAR_AUTH_STDIN:-none}"
    echo ready
    while :; do sleep 0.05; done
    """

    @Test("a supervised child reads the secret then the key on stdin, and the key is in no environment or argument")
    func childReceivesTheKeyOnlyOnStdin() async throws {
        let holder = CoreAuthSecret()
        let log = CoreAuthTests.Lines()
        let supervisor = CoreSupervisor(executable: "/bin/sh", arguments: ["-c", Self.reportScript],
                                        backoffScale: 0.02, authSecret: holder,
                                        sealKey: { SettingsSealHandoff(key: Self.key, isNew: true) })
        supervisor.onOutput = { stream, line in log.add("\(stream): \(line)") }
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0.3) }
        #expect(await CoreAuthTests.wait { log.readyCount >= 1 }, "\(log.lines)")

        let secret = try #require(holder.current)
        #expect(log.values("bytes") == [CoreAuthTests.hex(secret + Self.key)])
        #expect(log.values("envhits") == ["0"])
        #expect(log.values("arghits") == ["0"])
        #expect(log.values("announced") == ["3"])
        #expect(holder.current != Self.key, "the key is not the secret")
    }

    @Test("a key that has sealed before is announced as 2, and the supervisor asks for it at every start")
    func everyStartAsksForTheKey() async throws {
        let holder = CoreAuthSecret()
        let log = CoreAuthTests.Lines()
        let asked = AskCount()
        let supervisor = CoreSupervisor(executable: "/bin/sh", arguments: ["-c", Self.reportScript],
                                        backoffScale: 0.02, authSecret: holder,
                                        sealKey: { asked.bump(); return SettingsSealHandoff(key: Self.key, isNew: false) })
        supervisor.onOutput = { stream, line in log.add("\(stream): \(line)") }
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0.3) }
        #expect(await CoreAuthTests.wait { log.readyCount >= 1 })
        supervisor.restart()
        #expect(await CoreAuthTests.wait { log.readyCount >= 2 }, "\(log.lines)")

        #expect(log.values("announced") == ["2", "2"])
        #expect(asked.value == 2)
        let bytes = log.values("bytes")
        #expect(bytes.count == 2 && bytes[0].hasSuffix(CoreAuthTests.hex(Self.key)) && bytes[1].hasSuffix(CoreAuthTests.hex(Self.key)))
        #expect(bytes[0] != bytes[1], "a new secret each start, the same key")
    }

    @Test("a supervisor with no key provider hands the secret alone")
    func noProviderNoKey() async {
        let holder = CoreAuthSecret()
        let log = CoreAuthTests.Lines()
        let script = """
        echo "bytes=$(dd bs=64 count=1 2>/dev/null | wc -c | tr -d ' ')"
        echo "announced=${JRBAR_AUTH_STDIN:-none}"
        echo ready
        while :; do sleep 0.05; done
        """
        let supervisor = CoreSupervisor(executable: "/bin/sh", arguments: ["-c", script],
                                        backoffScale: 0.02, authSecret: holder)
        supervisor.onOutput = { stream, line in log.add("\(stream): \(line)") }
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0.3) }
        #expect(await CoreAuthTests.wait { log.readyCount >= 1 })

        #expect(log.values("bytes") == ["32"])
        #expect(log.values("announced") == ["1"])
    }

    @Test("a provider that has no key leaves the secret alone too")
    func providerWithoutKey() async {
        let holder = CoreAuthSecret()
        let log = CoreAuthTests.Lines()
        let script = """
        echo "announced=${JRBAR_AUTH_STDIN:-none}"
        echo ready
        while :; do sleep 0.05; done
        """
        let supervisor = CoreSupervisor(executable: "/bin/sh", arguments: ["-c", script],
                                        backoffScale: 0.02, authSecret: holder, sealKey: { nil })
        supervisor.onOutput = { stream, line in log.add("\(stream): \(line)") }
        supervisor.start()
        defer { supervisor.stop(gracePeriod: 0.3) }
        #expect(await CoreAuthTests.wait { log.readyCount >= 1 })

        #expect(log.values("announced") == ["1"])
    }

    /// A store that records which thread read the key.
    final class ThreadNotingStore: SettingsSealKeyStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var threads: [Bool] = []
        var readOnMain: [Bool] { lock.lock(); defer { lock.unlock() }; return threads }

        func loadOrCreate(allowPrompt: Bool) -> SettingsSealKeyResult {
            lock.lock(); threads.append(Thread.isMainThread); lock.unlock()
            return .key(SettingsSealKey(bytes: SettingsSealHandoffTests.key, sealedBefore: false))
        }

        func markSealed() -> Bool { true }
    }

    @Test("warming reads the Keychain off the calling thread, and the hand-off then reads nothing")
    func warmReadsOffMain() async {
        let store = ThreadNotingStore()
        let holder = SettingsSealKeyHolder(store: store)
        let queue = DispatchQueue(label: "jrbar.test.seal.warm")
        let done = CoreSupervisorTests.Flag()
        holder.warm(on: queue) { done.set() }
        #expect(await CoreSupervisorTests.wait { done.isSet })

        #expect(store.readOnMain == [false])
        #expect(holder.handoff()?.key == Self.key)
        #expect(store.readOnMain == [false], "the hand-off read the Keychain again")
    }

    final class AskCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
