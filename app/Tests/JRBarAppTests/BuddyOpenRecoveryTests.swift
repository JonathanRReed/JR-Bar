import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Buddy open recovery", .timeLimit(.minutes(10)))
struct BuddyOpenRecoveryTests {
    @MainActor
    private final class Replies {
        private var pending: [String: CheckedContinuation<CoreReply, Never>] = [:]
        private var arrivals: [String: CheckedContinuation<Void, Never>] = [:]

        func send(_ id: String) async -> CoreReply {
            await withCheckedContinuation { continuation in
                pending[id] = continuation
                arrivals.removeValue(forKey: id)?.resume()
            }
        }

        func waitFor(_ id: String) async {
            if pending[id] != nil { return }
            await withCheckedContinuation { arrivals[id] = $0 }
        }

        func finish(_ id: String) {
            pending.removeValue(forKey: id)?.resume(returning: CoreReply(
                id: id, ok: false, error: CoreReplyError(code: "not_found", message: "Synthetic window refusal")))
        }
    }

    @Test("replacement and shutdown retire every Buddy open before a late reply can start a fallback")
    func replacementAndShutdownRetireOpens() async throws {
        let core = CoreModel()
        let sessions = [CoreSession(id: "first", provider: "claude", mode: "waiting"),
                        CoreSession(id: "second", provider: "codex", mode: "waiting")]
        core.apply(.state(CoreState(sessions: sessions)))
        let toy = NotchBuddyToy(core: core, notificationCenter: NotificationCenter(), workspaceCenter: NotificationCenter())
        defer { toy.shutdown() }
        let replies = Replies()
        var raised: [String] = []
        var refused: [String] = []
        toy.onOpenRefused = { refused.append($0) }
        let wiring = SessionOpener.Wiring(send: { await replies.send($0) }, sessions: { sessions },
                                          raise: { raised.append($0); return true })
        toy.openSession = { await SessionOpener.open($0, via: wiring) }
        #expect(toy.openAskingSession(id: "first"))
        let first = try #require(toy.openInFlight)
        await replies.waitFor("first")
        #expect(toy.openAskingSession(id: "second"))
        let second = try #require(toy.openInFlight)
        await replies.waitFor("second")
        #expect(first.isCancelled)
        toy.shutdown()
        #expect(second.isCancelled)
        replies.finish("first")
        replies.finish("second")
        await first.value
        await second.value
        #expect(raised.isEmpty)
        #expect(refused.isEmpty)
        #expect(toy.openInFlight == nil)
    }

    @Test("a cancelled opener starts no daemon request or Dock fallback")
    func cancelledBeforeStarting() async {
        var calls: [String] = []
        let session = CoreSession(id: "fixture", provider: "claude", mode: "waiting")
        let wiring = SessionOpener.Wiring(
            send: { id in
                calls.append("send:\(id)")
                return CoreReply(id: "reply", ok: false, error: CoreReplyError(code: "not_found"))
            }, sessions: { [session] }, raise: { calls.append("raise:\($0)"); return true })
        let task = Task { await SessionOpener.open(session.id, via: wiring) }
        task.cancel()
        let result = await task.value
        #expect(calls.isEmpty)
        #expect(result != nil)
    }

    @Test("current refusals reach feedback and the shared card; success stays quiet", arguments: [false, true])
    func currentOutcomeIsReported(success: Bool) async throws {
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: [CoreSession(id: "fixture", provider: "claude", mode: "waiting")])))
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let toy = store.notchBuddy
        defer { toy.shutdown(); withExtendedLifetime(store) {} }
        let line = "The monitor is not answering"
        var received: [String] = []
        toy.onOpenRefused = { received.append($0) }
        toy.openSession = { _ in success ? nil : line }
        #expect(toy.openAskingSession(id: "fixture"))
        let task = try #require(toy.openInFlight)
        await task.value
        #expect(received == (success ? [] : [line]))
        #expect(store.notch.cardModel.openRefusals["fixture"] == (success ? nil : line))
        #expect(toy.openInFlight == nil)
    }

    @Test("an older refusal neither reports nor clears a newer open")
    func olderReplyDoesNotRetireNewerOpen() async throws {
        let core = CoreModel()
        let sessions = [CoreSession(id: "first", provider: "claude", mode: "waiting"),
                        CoreSession(id: "second", provider: "codex", mode: "waiting")]
        core.apply(.state(CoreState(sessions: sessions)))
        let toy = NotchBuddyToy(core: core, notificationCenter: NotificationCenter(), workspaceCenter: NotificationCenter())
        defer { toy.shutdown() }
        let replies = Replies()
        let wiring = SessionOpener.Wiring(send: { await replies.send($0) }, sessions: { sessions }, raise: { _ in false })
        var received: [String] = []
        toy.onOpenRefused = { received.append($0) }
        toy.openSession = { await SessionOpener.open($0, via: wiring) }
        #expect(toy.openAskingSession(id: "first"))
        let first = try #require(toy.openInFlight)
        await replies.waitFor("first")
        #expect(toy.openAskingSession(id: "second"))
        let second = try #require(toy.openInFlight)
        await replies.waitFor("second")
        replies.finish("first")
        await first.value
        #expect(received.isEmpty)
        #expect(toy.openInFlight != nil)
        #expect(!second.isCancelled)
        replies.finish("second")
        await second.value
        #expect(received == ["Synthetic window refusal"])
        #expect(toy.openInFlight == nil)
    }

    @Test("an invalid next target leaves the valid current open owned")
    func invalidReplacementKeepsCurrent() async throws {
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: [CoreSession(id: "fixture", provider: "claude", mode: "waiting")])))
        let toy = NotchBuddyToy(core: core, notificationCenter: NotificationCenter(), workspaceCenter: NotificationCenter())
        defer { toy.shutdown() }
        let replies = Replies()
        toy.openSession = { id in _ = await replies.send(id); return nil }
        #expect(toy.openAskingSession(id: "fixture"))
        let current = try #require(toy.openInFlight)
        await replies.waitFor("fixture")
        #expect(!toy.openAskingSession(id: "missing"))
        #expect(!current.isCancelled)
        replies.finish("fixture")
        await current.value
        #expect(toy.openInFlight == nil)
    }

    @Test("cancellation during an issued fallback cannot be reported as success")
    func cancelledDuringFallback() async {
        let replies = Replies()
        let session = CoreSession(id: "fixture", provider: "claude", mode: "waiting")
        let wiring = SessionOpener.Wiring(
            send: { _ in CoreReply(id: "reply", ok: false, error: CoreReplyError(code: "not_found")) },
            sessions: { [session] }, raise: { id in _ = await replies.send(id); return true })
        let task = Task { await SessionOpener.open(session.id, via: wiring) }
        await replies.waitFor("fixture")
        task.cancel()
        replies.finish("fixture")
        #expect(await task.value != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func feedbackComponents() async throws {
        let core = CoreModel()
        core.apply(.state(CoreState(sessions: [CoreSession(id: "fixture", provider: "claude", mode: "waiting")])))
        let toy = NotchBuddyToy(core: core, notificationCenter: NotificationCenter(), workspaceCenter: NotificationCenter())
        defer { toy.shutdown() }
        var reported: String?
        toy.onOpenRefused = { reported = $0 }
        toy.openSession = { _ in SessionOpener.notAnswering }
        #expect(toy.openAskingSession(id: "fixture"))
        let task = try #require(toy.openInFlight)
        await task.value
        let text = try #require(reported)
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let application = NSApplication.shared
        let previous = application.appearance
        defer { application.appearance = previous }
        for dark in [false, true] {
            application.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for hud in [false, true] {
                let view = ZStack {
                    Color(white: dark ? 0.16 : 0.95)
                    if hud {
                        PaletteHUDView(text: text, symbol: "exclamationmark.circle.fill")
                    } else {
                        ToastView(text: text, reduced: true).frame(width: CGFloat(PanelLayout.width))
                    }
                }
                .frame(width: 420, height: 90)
                .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = "buddy-refusal-\(hud ? "hud" : "toast")-\(dark ? "dark" : "light").png"
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
