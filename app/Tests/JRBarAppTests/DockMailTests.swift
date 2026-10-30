import AppKit
import JRBarCore
import JRBarTestSupport
import os
import Testing
@testable import JRBarApp

@MainActor
@Suite("Dock Mail preview", .serialized, .timeLimit(.minutes(2)))
struct DockMailTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    nonisolated static let output = "9\u{1e}synthetic-1@example.invalid\u{1f}Morgan Lee\u{1f}Synthetic review\u{1f}-120\u{1f}true"

    private func settle(_ preview: DockMailPreview) async {
        await withCheckedContinuation { continuation in
            preview.queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func preview(permission: AutomationPermission = .granted,
                         result: Result<String, DockMailError> = .success(Self.output)) -> DockMailPreview {
        let reader = DockMailReader(isRunning: { true }, permission: { ask in
            #expect(!ask)
            return permission
        }, runner: { _, _, _ in result })
        let preview = DockMailPreview(reader: reader)
        preview.clock = { Self.now }
        return preview
    }

    @Test("off never creates a reader or cache, preflights or spawns; disabling drops all held state")
    func off() async throws {
        let readers = DockNativePreviews()
        var creations = 0
        let mail = preview()
        readers.makeMail = { creations += 1; return mail }
        let card = DockPreviewContent()
        card.bundleID = DockEnhanceMath.mailBundleID
        card.isRunning = true
        var settings = DockEnhanceSettings(calendarPreview: false, mediaPreview: false)
        readers.seed(content: card, settings: settings)
        readers.start(content: card, settings: settings)
        #expect(creations == 0 && readers.mail == nil && card.mailState == nil)
        #expect(!settings.mailPreview)
        for json in ["{}", #"{"mailPreview":null}"#, #"{"mailPreview":"yes"}"#] {
            #expect(try !JSONDecoder().decode(DockEnhanceSettings.self, from: Data(json.utf8)).mailPreview)
        }
        settings.mailPreview = true
        readers.update(settings: settings)
        await settle(mail)
        #expect(creations == 1 && mail.cached != nil)
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(DockEnhanceSettings.self, from: encoded).mailPreview)
        readers.stop()
        #expect(!mail.visible && readers.mail == nil && readers.mailCache != nil)
        settings.mailPreview = false
        readers.discardMailIfDisabled(settings)
        #expect(readers.mail == nil && mail.cached == nil && readers.mailCache == nil)
        readers.start(content: card, settings: settings)
        #expect(creations == 1 && card.mailState == nil)
        readers.stop()
    }

    @Test("a new visible reader reuses the held cache and a badge change invalidates it")
    func readerReleasedBetweenCards() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let readers = DockNativePreviews()
        readers.makeMail = {
            let reader = DockMailReader(isRunning: { true }, permission: { _ in .granted }, runner: { _, _, _ in
                reads.withLock { $0 += 1 }; return .success(Self.output)
            })
            let mail = DockMailPreview(reader: reader)
            mail.clock = { Self.now }
            return mail
        }
        let card = DockPreviewContent()
        card.bundleID = DockEnhanceMath.mailBundleID
        card.isRunning = true
        card.badge = "9"
        let settings = DockEnhanceSettings(calendarPreview: false, mediaPreview: false, mailPreview: true)
        readers.start(content: card, settings: settings)
        let first = try #require(readers.mail)
        await settle(first)
        readers.stop()
        #expect(readers.mail == nil && first.cached == nil)
        readers.start(content: card, settings: settings)
        let second = try #require(readers.mail)
        #expect(first !== second)
        await settle(second)
        #expect(reads.withLock { $0 } == 1)
        readers.badgeChanged("10")
        await settle(second)
        #expect(reads.withLock { $0 } == 2 && card.badge == "10")
        readers.stop()
        readers.discardMail()
        #expect(readers.mailCache == nil)
    }

    @Test("closed Mail does not preflight, read or launch, even for explicit permission requests")
    func noLaunch() async {
        let reader = DockMailReader(isRunning: { false }, permission: { _ in
            Issue.record("closed Mail must not preflight"); return .granted
        }, runner: { _, _, _ in Issue.record("closed Mail must not spawn"); return .failure(.failed) })
        let mail = DockMailPreview(reader: reader)
        var state: DockMailPreview.State?
        mail.onChange = { state = $0 }
        mail.show(badge: nil)
        await settle(mail)
        #expect(state == .notRunning)
        #expect(reader.read(now: Self.now, cancellation: DockMailCancellation()) == .failure(.unavailable))
        for ask in [false, true] {
            let permission = AutomationPermission.target("com.apple.mail", ask: ask, isRunning: { _ in false }, determine: { _, _ in
                Issue.record("closed target must not receive an Apple event"); return 0
            })
            #expect(permission == .unavailable)
        }
        mail.hide()
    }

    @Test("hover never asks and every permission status has an honest state",
          arguments: [AutomationPermission.granted, .needsConsent, .denied, .unavailable])
    func statuses(_ permission: AutomationPermission) async {
        let mail = preview(permission: permission)
        var state: DockMailPreview.State?
        mail.onChange = { state = $0 }
        mail.show(badge: "9")
        await settle(mail)
        switch permission {
        case .granted: #expect(state?.reading?.unread == 9)
        case .needsConsent: #expect(state == .noAccess)
        case .denied: #expect(state == .denied)
        case .unavailable: #expect(state == .notRunning)
        }
        mail.hide()
    }

    @Test("the explicit button uses PermissionRequest for every status",
          arguments: [SetupPermissionStatus.needed, .granted, .denied, .restricted, .unknown, .unavailable, .writeOnly])
    func requestStatuses(_ status: SetupPermissionStatus) async {
        let mail = preview()
        mail.show(badge: nil)
        await settle(mail)
        defer { mail.hide() }
        var effects: [String] = []
        let requestOverride: @MainActor @Sendable (SetupPermission, PermissionRequest) -> PermissionRequest = { permission, original in
            #expect(permission == .automation)
            #expect(original.settingsURL == AutomationPermission.settingsURL)
            return PermissionRequest(status: { status }, prompt: { effects.append("prompt") },
                settingsURL: original.settingsURL, activate: { effects.append("activate") },
                openSettings: { _ in effects.append("settings") },
                explainFullAccess: { effects.append("explain") }, refresh: { effects.append("refresh") })
        }
        await PermissionRequest.$override.withValue(requestOverride) { await mail.requestAccess() }
        if status == .needed { #expect(effects == ["activate", "prompt", "refresh"]) }
        else if status == .granted { #expect(effects == ["refresh"]) }
        else if status == .writeOnly { #expect(effects == ["activate", "explain", "settings", "refresh"]) }
        else { #expect(effects == ["settings", "refresh"]) }
    }

    @Test("empty, messages, timeout and stale preserve only the last good reading")
    func readingStates() async {
        let result = OSAllocatedUnfairLock(initialState: Result<String, DockMailError>.success("0"))
        let reader = DockMailReader(isRunning: { true }, permission: { _ in .granted },
            runner: { _, _, _ in result.withLock { $0 } })
        let mail = DockMailPreview(reader: reader)
        mail.clock = { Self.now }
        var state: DockMailPreview.State?
        mail.onChange = { state = $0 }
        mail.show(badge: nil)
        await settle(mail)
        #expect(state?.reading?.unread == 0 && state?.reading?.messages.isEmpty == true)
        result.withLock { $0 = .success(Self.output) }
        mail.refresh(force: true)
        await settle(mail)
        let good = mail.cached
        #expect(good?.messages.count == 1)
        result.withLock { $0 = .failure(.timeout) }
        mail.refresh(force: true)
        await settle(mail)
        #expect(state == good.map { .stale($0) })
        #expect(mail.cached == good)
        mail.hide()
        let cold = preview(result: .failure(.timeout))
        cold.onChange = { state = $0 }
        cold.show(badge: nil)
        await settle(cold)
        #expect(state == .timeout)
        cold.hide()
    }

    @Test("30-second cache, badge invalidation and closed-card lifecycle need no polling")
    func cacheAndBadge() async {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let reader = DockMailReader(isRunning: { true }, permission: { _ in .granted }, runner: { _, _, _ in
            reads.withLock { $0 += 1 }; return .success(Self.output)
        })
        let mail = DockMailPreview(reader: reader)
        var now = Self.now
        mail.clock = { now }
        mail.show(badge: "9")
        await settle(mail)
        mail.hide()
        now = now.addingTimeInterval(29)
        mail.show(badge: "9")
        await settle(mail)
        #expect(reads.withLock { $0 } == 1)
        mail.badgeChanged("10")
        await settle(mail)
        #expect(reads.withLock { $0 } == 2)
        mail.badgeChanged("10")
        await settle(mail)
        #expect(reads.withLock { $0 } == 2)
        now = now.addingTimeInterval(30)
        mail.refresh()
        await settle(mail)
        #expect(reads.withLock { $0 } == 3)
        mail.hide()
        mail.badgeChanged("11")
        mail.refresh(force: true)
        NotificationCenter.default.post(name: PermissionRequest.didChange, object: nil)
        await settle(mail)
        #expect(reads.withLock { $0 } == 3)
    }

    @Test("hiding during a read cancels its child and drops the late result")
    func lateRead() async {
        let entered = TestSignal()
        let gate = TestGate()
        defer { gate.signal() }
        let reader = DockMailReader(isRunning: { true }, permission: { _ in .granted }, runner: { _, _, cancellation in
            entered.signal(); gate.wait()
            #expect(cancellation.cancelled)
            return .success(Self.output)
        })
        let mail = DockMailPreview(reader: reader)
        mail.show(badge: nil)
        #expect(await entered.wait())
        mail.hide()
        gate.signal()
        await settle(mail)
        #expect(mail.cached == nil)
    }

    @Test("revoking access during a read drops its message data", arguments: [AutomationPermission.denied, .unavailable])
    func revokedDuringRead(_ permission: AutomationPermission) async {
        let gate = TestGate()
        let entered = TestSignal()
        defer { gate.signal() }
        let status = OSAllocatedUnfairLock(initialState: AutomationPermission.granted)
        let reader = DockMailReader(isRunning: { true }, permission: { _ in status.withLock { $0 } }, runner: { _, _, _ in
            entered.signal(); gate.wait(); return .success(Self.output)
        })
        let mail = DockMailPreview(reader: reader)
        var state: DockMailPreview.State?
        mail.onChange = { state = $0 }
        mail.show(badge: nil)
        #expect(await entered.wait())
        status.withLock { $0 = permission }
        gate.signal()
        await settle(mail)
        #expect(mail.cached == nil)
        #expect(state == (permission == .denied ? .denied : .notRunning))
        mail.hide()
    }

    @Test("hostile fields are bounded, Unicode survives, and injected separators fail closed")
    func parser() throws {
        let name = String(repeating: "名", count: 100) + "\u{0}\n\u{202e}"
        let subject = String(repeating: "مرحبا 世界", count: 80) + "\u{7}\t"
        let raw = "1\u{1e}synthetic@example.invalid\u{1f}\(name)\u{1f}\(subject)\u{1f}-120\u{1f}true"
        let parsed = try DockMailReader.parse(raw, now: Self.now)
        let message = try #require(parsed.messages.first)
        #expect(message.sender.count == 60 && message.subject.count == 120)
        #expect(!message.sender.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        #expect(!message.subject.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        #expect(message.received == Self.now.addingTimeInterval(-120))
        #expect(message.flagged && message.url?.scheme == "message")
        #expect(message.url?.absoluteString.contains("%3Csynthetic%40example.invalid%3E") == true)
        #expect(DockMailReader.clean("a\u{1f}b\u{1e}c\u{0}\u{202e}d", limit: 120) == "abcd")
        let hostile = Self.output.replacingOccurrences(of: "Synthetic review", with: "Subject\u{1f}false")
        #expect(throws: DockMailError.malformed) { try DockMailReader.parse(hostile, now: Self.now) }
        for output in ["-1", "1\u{1e}bad", "1\u{1e}bad\u{1f}Name\u{1f}Subject\u{1f}nan\u{1f}false", String(repeating: "x", count: 65_537)] {
            #expect(throws: DockMailError.malformed) { try DockMailReader.parse(output, now: Self.now) }
        }
        let emptyFields = "1\u{1e}synthetic@example.invalid\u{1f}sender@example.invalid\u{1f}\u{1f}0\u{1f}false"
        let fallback = try DockMailReader.parse(emptyFields, now: Self.now)
        #expect(fallback.messages.first?.sender == "Unknown sender")
        #expect(fallback.messages.first?.subject == "No subject")
        let rows = (0..<5).map { "id-\($0)\u{1f}Name\u{1f}Subject\u{1f}\(-$0)\u{1f}false" }
        let many = try DockMailReader.parse((["5"] + rows.reversed()).joined(separator: "\u{1e}"), now: Self.now)
        #expect(many.messages.map(\.id) == ["id-0", "id-1", "id-2", "id-3", "id-4"])
        let duplicate = "2\u{1e}" + Self.output.components(separatedBy: "\u{1e}")[1]
            + "\u{1e}" + Self.output.components(separatedBy: "\u{1e}")[1]
        #expect(try DockMailReader.parse(duplicate, now: Self.now).messages.count == 1)
    }

    @Test("Reply passes the opaque identifier as argv, opens a window, and never sends")
    func reply() async throws {
        let calls = OSAllocatedUnfairLock(initialState: [(String, [String])]())
        let reader = DockMailReader(isRunning: { true }, permission: { _ in .granted }, runner: { script, argv, _ in
            calls.withLock { $0.append((script, argv)) }
            return .success(argv.isEmpty ? Self.output : "opened")
        })
        let mail = DockMailPreview(reader: reader)
        mail.show(badge: nil)
        await settle(mail)
        let message = try #require(mail.cached?.messages.first)
        mail.reply(message)
        await settle(mail)
        let recorded = calls.withLock { $0 }
        #expect(recorded.count == 2 && recorded[1].1 == [message.id])
        #expect(recorded[1].0.contains("reply m with opening window"))
        #expect(!recorded[1].0.contains("send "))
        mail.hide()
        mail.reply(message)
        await settle(mail)
        #expect(calls.withLock { $0.count } == 2)
    }

    @Test("the production field encoder removes separators before joining, using synthetic text only")
    func scriptFieldEncoder() async {
        let helper = DockMailReader.script.components(separatedBy: "if not application id")[0]
        let script = helper + "\non run argv\nreturn my safeText(item 1 of argv, 120)\nend run"
        let result = await Task.detached {
            DockMailReader.run(script, ["世界\u{1e} مرحبا\u{1f} 👍"], DockMailCancellation())
        }.value
        #expect(result == .success("世界 مرحبا 👍\n"))
    }

    @Test("the hard deadline kills a nonresponsive synthetic script without Mail")
    func runnerTimeout() async {
        let result = await Task.detached {
            DockMailReader.run("repeat\nend repeat", [], DockMailCancellation())
        }.value
        #expect(result == .failure(.timeout))
        let cancelled = DockMailCancellation()
        cancelled.cancel()
        #expect(DockMailReader.run("return \"unused\"", [], cancelled) == .failure(.failed))
    }

    @Test("the real runner accepts argv without shell expansion using only synthetic text")
    func runnerArguments() async {
        let value = "synthetic \"quote\" ; $(false) `false` \u{1f}世界"
        let result = await Task.detached {
            DockMailReader.run("on run argv\nreturn item 1 of argv\nend run", [value], DockMailCancellation())
        }.value
        #expect(result == .success(value + "\n"))
    }
}
