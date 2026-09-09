import Foundation
import Testing
@testable import JRBarCore

enum CoreFixtures {
    static var root: URL { Bundle.module.resourceURL!.appending(path: "Fixtures") }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: root.appending(path: name))
    }

    static func message(_ name: String) throws -> CoreMessage {
        try CoreCodec.decode(frame: data(name))
    }
}

@Suite("Protocol codec")
struct CodecTests {
    @Test("hello decodes, unknown keys ignored")
    func hello() throws {
        guard case .hello(let hello) = try CoreFixtures.message("hello.json") else {
            Issue.record("not a hello"); return
        }
        #expect(hello.coreVersion == "0.8.0")
        #expect(hello.pid == 123)
        #expect(hello.capabilities.count == 10)
        #expect(hello.capabilities.contains("lights"))
    }

    @Test("state decodes every documented field")
    func state() throws {
        guard case .state(let state) = try CoreFixtures.message("state.json") else {
            Issue.record("not a state"); return
        }
        #expect(state.generation == 4812)
        #expect(state.now == 1788982892.4)
        #expect(state.aggregate.mode == "working")
        #expect(state.aggregate.active == 2)
        #expect(state.aggregate.ready == 1)
        #expect(state.sessions.count == 3)
        #expect(state.mainSessions.count == 2)

        let claude = try #require(state.session(withID: "claude:session:fca1eb06-f6d1"))
        #expect(claude.provider == "claude")
        #expect(claude.kind == "main")
        #expect(claude.parent == nil)
        #expect(claude.label == "jr-bar-b7")
        #expect(claude.cwd == "/Users/j/Downloads/JR-Bar")
        #expect(claude.mode == "tool_running")
        #expect(claude.lifecycle == "active")
        #expect(claude.nextActor == "provider")
        #expect(claude.since == 1788978889.9)
        #expect(claude.updatedAt == 1788982891.0)
        #expect(claude.stale == false)
        #expect(claude.pid == 9170)
        #expect(claude.origin?.bundleId == "com.anthropic.claudefordesktop")
        #expect(claude.ask == nil)
        #expect(claude.terminal?.app == "Ghostty")
        #expect(claude.terminal?.tty == "/dev/ttys004")
        #expect(claude.workers == 2)

        let codex = try #require(state.session(withID: "codex:session:0f3b"))
        #expect(codex.ask?.summary == "Run: rm -rf build")
        #expect(codex.ask?.kind == "permission")
        #expect(codex.workers == 0)

        let worker = try #require(state.session(withID: "claude:session:fca1eb06-f6d1:worker:1"))
        #expect(worker.kind == "worker")
        #expect(worker.parent == claude.id)

        #expect(state.asks.count == 1)
        #expect(state.asks[0].session == "codex:session:0f3b")
        #expect(state.asks[0].openedAt == 1788982800.0)

        #expect(state.devices.count == 3)
        let pro = state.devices[0]
        #expect(pro.kind == "pro")
        #expect(pro.brightness == 79)
        #expect(pro.brightnessFraction == 0.79)
        #expect(pro.isPresent)
        #expect(pro.error == nil)
        #expect(state.devices[2].kind == "screen_bar")
        #expect(state.devices[2].enabled == true)
        #expect(state.devices[2].isPresent)

        let usage = try #require(state.usage)
        #expect(usage.refreshedAt == 1788982850.0)
        #expect(usage.providers.count == 2)
        #expect(usage.providers[0].windows.map(\.name) == ["5h", "7d"])
        #expect(usage.providers[0].windows[1].usedPct == 61.0)
        #expect(usage.providers[0].forecast?.pace == "ahead")
        #expect(usage.providers[0].isDerived == false)
        #expect(usage.providers[1].isDerived)
        #expect(usage.providers[1].windows[0].resetsAt == nil)

        #expect(state.power?.keepAwake == true)
        #expect(state.power?.closedLid?.policy == "agents")
        #expect(state.focus?.mode == "dim")
        #expect(state.escalation?.stage == "none")
        #expect(state.escalation?.since == nil)
        #expect(state.health?["hooks"]?["pi"]?.stringValue == "missing")
        #expect(state.settingsGeneration == 17)
    }

    @Test("lights decodes surfaces, including ones this build does not name")
    func lights() throws {
        guard case .lights(let lights) = try CoreFixtures.message("lights.json") else {
            Issue.record("not lights"); return
        }
        #expect(lights.linked == true)
        #expect(lights.surfaces.count == 4)
        let bar = try #require(lights.screenBar)
        #expect(bar.program.hasPrefix("off 160ms cosine\n#FF3A00"))
        #expect(bar.ledCount == 8)
        #expect(bar.anchor == 1788982891.31)
        #expect(bar.motion == "beat")
        #expect(bar.staticFallback == "#FF3A00")
        #expect(bar.brightness == nil)
        #expect(bar.why == "needs_you")
        #expect(lights.hardware?.brightness == 0.79)
        #expect(lights.dot?.ledCount == 2)
        #expect(lights.surfaces["future_surface"]?.ledCount == 16)
    }

    @Test("event, settings, replies and log decode")
    func others() throws {
        guard case .event(let event) = try CoreFixtures.message("event.json") else {
            Issue.record("not an event"); return
        }
        #expect(event.id == "ev-77")
        #expect(event.kind == "completed")
        #expect(event.session == "claude:session:fca1eb06-f6d1")
        #expect(event.label == "jr-bar-b7")
        #expect(event.sound == "glass")
        #expect(event.notify == true)

        guard case .settings(let settings) = try CoreFixtures.message("settings.json") else {
            Issue.record("not settings"); return
        }
        #expect(settings.generation == 17)
        #expect(settings.schema == 3)
        #expect(settings.document["screen_bar"]?["wrap_menu_bar"]?.boolValue == true)
        #expect(settings.document["devices"]?["sidepulse:pro:B293"]?["brightness"]?.doubleValue == 0.79)
        #expect(settings.document["list"]?[2]?.isNull == true)
        #expect(settings.document["list"]?[1]?.stringValue == "two")

        guard case .reply(let ok) = try CoreFixtures.message("reply_ok.json") else {
            Issue.record("not a reply"); return
        }
        #expect(ok.id == "c-42")
        #expect(ok.ok)
        #expect(ok.result?["activated"]?.stringValue == "Ghostty")
        #expect(ok.result?["generation"]?.intValue == 18)
        #expect(ok.error == nil)

        guard case .reply(let failed) = try CoreFixtures.message("reply_error.json") else {
            Issue.record("not a reply"); return
        }
        #expect(failed.id == "c-43")
        #expect(!failed.ok)
        #expect(failed.error?.code == "not_found")
        #expect(failed.error?.message == "no such session")

        guard case .log(let log) = try CoreFixtures.message("log.json") else {
            Issue.record("not a log"); return
        }
        #expect(log.level == "info")
        #expect(log.message == "hooks drained")
    }

    @Test("unknown types and future versions are not errors")
    func unknown() throws {
        guard case .unknown(let type, let version) = try CoreFixtures.message("unknown_type.json") else {
            Issue.record("should be unknown"); return
        }
        #expect(type == "peers")
        #expect(version == 1)
        guard case .unknown(let type2, let version2) = try CoreFixtures.message("future_version.json") else {
            Issue.record("a future version should not be decoded as state"); return
        }
        #expect(type2 == "state")
        #expect(version2 == 2)
    }

    @Test("malformed frames throw specific errors")
    func malformed() {
        #expect(throws: CoreCodecError.emptyFrame) { try CoreCodec.decode(frame: Data()) }
        #expect(throws: CoreCodecError.missingType) { try CoreCodec.decode(line: #"{"v":1}"#) }
        #expect(throws: CoreCodecError.notAnObject) { try CoreCodec.decode(line: "[1,2]") }
        #expect(throws: CoreCodecError.self) { try CoreCodec.decode(line: "{not json") }
        #expect(throws: CoreCodecError.self) { try CoreCodec.decode(line: #"{"t":"state","v":1,"sessions":"nope"}"#) }
        let big = Data(repeating: 0x20, count: CoreCodec.maxFrameBytes + 1)
        #expect(throws: CoreCodecError.frameTooLarge(big.count)) { try CoreCodec.decode(frame: big) }
    }

    @Test("a minimal state decodes with defaults")
    func minimalState() throws {
        guard case .state(let state) = try CoreCodec.decode(line: #"{"t":"state","v":1}"#) else {
            Issue.record("not a state"); return
        }
        #expect(state.generation == 0)
        #expect(state.aggregate.mode == "idle")
        #expect(state.sessions.isEmpty)
        #expect(state.devices.isEmpty)
        #expect(state.usage == nil)
    }

    @Test("commands encode to the documented frame")
    func encodeCommand() throws {
        let command = CoreCommand(id: "c-42", name: "open_session", args: ["session": "claude:session:fca1eb06-f6d1"])
        let bytes = try CoreCodec.encode(command: command)
        #expect(bytes.last == 0x0A)
        let text = String(decoding: bytes.dropLast(), as: UTF8.self)
        #expect(!text.contains("\n"))
        let expected = try JSONSerialization.jsonObject(with: CoreFixtures.data("command_open_session.json")) as? NSDictionary
        let actual = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary
        #expect(actual == expected)

        let roundTrip = try CoreCodec.decodeCommand(frame: Data(text.utf8))
        #expect(roundTrip == command)

        let ask = CoreCommand(id: "c-7", name: "answer_ask", args: [
            "session": "codex:session:0f3b", "decision": "approve", "only_if_frontmost": true,
        ])
        let askText = String(decoding: try CoreCodec.encode(command: ask), as: UTF8.self)
        #expect(askText.contains(#""only_if_frontmost":true"#))
        #expect(askText.contains(#""t":"command""#))
        #expect(askText.contains(#""v":1"#))

        let brightness = CoreCommand(id: "c-8", name: "set_brightness", args: ["device": "all", "value": 0.65])
        let brightnessText = String(decoding: try CoreCodec.encode(command: brightness), as: UTF8.self)
        #expect(brightnessText.contains(#""value":0.65"#))
    }

    @Test("the NDJSON splitter handles partial frames and CRLF")
    func splitter() {
        var splitter = NDJSONSplitter()
        #expect(splitter.feed(Data(#"{"t":"hel"#.utf8)).isEmpty)
        let frames = splitter.feed(Data("lo\",\"v\":1}\r\n\n{\"t\":\"log\",\"v\":1}\n{\"t\":".utf8))
        #expect(frames.count == 2)
        #expect(String(decoding: frames[0], as: UTF8.self) == #"{"t":"hello","v":1}"#)
        #expect(String(decoding: frames[1], as: UTF8.self) == #"{"t":"log","v":1}"#)
        let tail = splitter.feed(Data("\"x\",\"v\":1}\n".utf8))
        #expect(tail.count == 1)
        #expect(String(decoding: tail[0], as: UTF8.self) == #"{"t":"x","v":1}"#)
    }

    @Test("backoff follows 0.5, 1, 2, cap 5")
    func backoff() {
        #expect(CoreBackoff.delay(afterFailures: 1) == 0.5)
        #expect(CoreBackoff.delay(afterFailures: 2) == 1.0)
        #expect(CoreBackoff.delay(afterFailures: 3) == 2.0)
        #expect(CoreBackoff.delay(afterFailures: 4) == 4.0)
        #expect(CoreBackoff.delay(afterFailures: 5) == 5.0)
        #expect(CoreBackoff.delay(afterFailures: 40) == 5.0)
    }

    @Test("socket path resolution honours the override and XDG")
    func socketPath() {
        #expect(CoreSocketPath.resolve(environment: ["JRBAR_CORE_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
        #expect(CoreSocketPath.resolve(environment: ["XDG_STATE_HOME": "/tmp/state"]) == "/tmp/state/jrbar/core.sock")
        #expect(CoreSocketPath.resolve(environment: [:]).hasSuffix("/.local/state/jrbar/core.sock"))
    }

    @Test("the model applies documents and dedupes events")
    @MainActor
    func model() throws {
        let model = CoreModel(socketPath: "/nonexistent.sock")
        var seen: [String] = []
        model.onEvent = { seen.append($0.id) }
        model.apply(try CoreFixtures.message("hello.json"))
        model.apply(try CoreFixtures.message("state.json"))
        model.apply(try CoreFixtures.message("lights.json"))
        model.apply(try CoreFixtures.message("settings.json"))
        model.apply(try CoreFixtures.message("event.json"))
        model.apply(try CoreFixtures.message("event.json"))
        model.apply(try CoreFixtures.message("unknown_type.json"))
        #expect(model.hello?.pid == 123)
        #expect(model.sessions.count == 2)
        #expect(model.openAsks.count == 1)
        #expect(model.devices.count == 3)
        #expect(model.usage.count == 2)
        #expect(model.lights?.screenBar?.why == "needs_you")
        #expect(model.settings?.generation == 17)
        #expect(seen == ["ev-77"])
        #expect(model.unknownMessageCount == 1)
        #expect(model.isLive == false, "no socket means the file feeds stay in charge")
    }
}
