import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Notch focused asks", .serialized)
@MainActor
struct NotchFocusedAskTests {
    @Test("the focused waiting ask keeps its controls and incoming priority")
    func waitingFocusRemains() {
        let rows = NotchFocusedAskFixture.rows()
        let filtered = NotchCardModel.rowsForCard(rows, focusSession: NotchFocusedAskFixture.session)
        #expect(filtered == rows)
        #expect(filtered.first?.ask?.request == "request-1")
        #expect(filtered.first?.ask?.preview == "make test")
    }

    @Test("a focused working session stays in the header while other asks remain")
    func workingFocusIsOmitted() {
        let rows = NotchFocusedAskFixture.rows()
        let filtered = NotchCardModel.rowsForCard(rows, focusSession: "codex:working")
        #expect(filtered.map(\.id) == [NotchFocusedAskFixture.session])
        #expect(NotchCardModel.rowsForCard(rows, focusSession: nil) == rows)
    }

    @Test("missing and already answered asks do not duplicate the focused header")
    func inactiveAskIsOmitted() {
        var row = NotchFocusedAskFixture.rows()[0]
        row.ask = nil
        #expect(NotchCardModel.rowsForCard([row], focusSession: row.id).isEmpty)
        var answered = NotchFocusedAskFixture.ask()
        answered.decision = CoreAskDecision(decided: true)
        row.ask = answered
        #expect(NotchCardModel.rowsForCard([row], focusSession: row.id).isEmpty)
    }

    @Test("the glass presenter keeps the focused ask without answering it")
    func glassPresenterKeepsAsk() throws {
        let fixture = try NotchFocusedAskFixture()
        defer { fixture.cleanUp() }
        let presenter = NotchCardPresenter(model: fixture.model)
        presenter.presentationEnabled = false
        presenter.surface = { .glass }
        presenter.focus = { NotchFocusedAskFixture.focus }
        presenter.sessionRows = { NotchFocusedAskFixture.rows() }
        presenter.anchor = { CGRect(x: 400, y: 600, width: 185, height: 32) }
        defer { presenter.panel.orderOut(nil) }
        var answers = 0
        let desk = AskAnswerDesk(send: { _, _, _ in
            answers += 1
            return CoreReply(id: "fixture", ok: true)
        })
        fixture.model.askDesk = { desk }
        presenter.peek()
        #expect(!presenter.panel.isVisible)
        #expect(fixture.model.rows.first?.id == NotchFocusedAskFixture.session)
        #expect(fixture.model.rows.first?.ask?.request == "request-1")
        #expect(answers == 0)
    }

    @Test("expanding the island keeps the focused ask without answering it")
    func islandKeepsAsk() throws {
        let fixture = try NotchFocusedAskFixture()
        defer { fixture.cleanUp() }
        var settings = ToysState()
        settings.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-focused-ask-fixture.sock")
        let ask = NotchFocusedAskFixture.ask()
        core.apply(.state(CoreState(sessions: [
            CoreSession(id: NotchFocusedAskFixture.session, provider: "claude", label: "review-patch", ask: ask),
            CoreSession(id: "codex:working", provider: "codex", label: "run-checks", mode: "working"),
        ], asks: [ask])))
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: settings,
                              cardModel: fixture.model, notchRuntimeEnabled: false)
        let toy = try #require(store.notch)
        defer { toy.collapseFromBand(); withExtendedLifetime(store) {} }
        toy.islandVisible = true
        toy.cardFocus = { NotchFocusedAskFixture.focus }
        var answers = 0
        let desk = AskAnswerDesk(send: { _, _, _ in
            answers += 1
            return CoreReply(id: "fixture", ok: true)
        })
        fixture.model.askDesk = { desk }
        toy.expandFromBand()
        #expect(toy.islandExpanded)
        let focusedRows = fixture.model.rows.filter { $0.id == NotchFocusedAskFixture.session }
        #expect(focusedRows.count == 1)
        #expect(focusedRows.first?.ask?.request == "request-1")
        #expect(answers == 0)
    }
}

@Suite("Notch focused ask render proof", .serialized)
@MainActor
struct NotchFocusedAskRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write focused ask PNGs"))
    func focusedAskAndMixedNow() throws {
        for mixed in [false, true] {
            let media = mixed ? AlcoveMedia(title: "Quiet Hours", artist: "Fixture Artist", album: "Fixture Album",
                playing: true, bundleIdentifier: "com.apple.Music", duration: 240, elapsed: 60,
                timestamp: Date().timeIntervalSince1970) : nil
            let fixture = try NotchFocusedAskFixture(media: media)
            defer { fixture.cleanUp() }
            fixture.model.focus = NotchFocusedAskFixture.focus
            let rows = NotchFocusedAskFixture.rows()
            fixture.model.rows = NotchCardModel.rowsForCard(mixed ? rows : Array(rows.prefix(1)),
                focusSession: NotchFocusedAskFixture.session)
            let desk = AskAnswerDesk(send: { _, _, _ in
                Issue.record("Rendering a focused ask must not answer it")
                return CoreReply(id: "fixture", ok: true)
            })
            fixture.model.askDesk = { desk }
            if mixed {
                fixture.model.timers.add(label: "Tea", duration: 300)
                fixture.model.meters = [NotchIslandMeter(id: "claude", provider: "claude", window: "5h", percent: 42)]
            }
            let card = NotchCardView(model: fixture.model, style: .island, width: NotchCardView.width,
                                     pinnedLayout: true)
            let host = NSHostingView(rootView: card)
            host.layoutSubtreeIfNeeded()
            let height = ceil(host.fittingSize.height)
            #expect(height > 100)
            let scene = card.background(.black, in: RoundedRectangle(cornerRadius: 28))
            try ProofRender.write(scene, size: CGSize(width: NotchCardView.width, height: height),
                                  name: mixed ? "notch-focused-ask-mixed-now" : "notch-focused-ask-now")
        }
    }
}

@MainActor
private struct NotchFocusedAskFixture {
    static let session = "claude:waiting"
    static let focus = ScreenBarFocus(style: ProviderStyle.style(for: "claude"), label: "review-patch",
                                      word: "Needs you", clickSession: session, focusSession: session)
    let model: NotchCardModel
    private let directory: URL
    private let defaults: UserDefaults
    private let suite: String

    init(media: AlcoveMedia? = nil) throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let fixtureSuite = ScratchDefaults.suiteName("NotchFocusedAskTests")
        let fixtureDefaults = try #require(UserDefaults(suiteName: fixtureSuite))
        let noBattery = AlcovePowerState(hasBattery: false, onAC: false, charging: false,
                                        percent: nil, fullyCharged: false)
        model = NotchCardModel(
            timers: ShelfTimerModel(storeURL: fixtureDirectory.appendingPathComponent("timers.json"), schedulingEnabled: false),
            tray: ShelfTrayModel(defaults: fixtureDefaults),
            utility: ShelfUtilityModel(media: media, power: noBattery), runtimeEnabled: false)
        directory = fixtureDirectory
        suite = fixtureSuite
        defaults = fixtureDefaults
        model.onOpenRow = { _ in }
        model.onOpenOverview = {}
    }

    static func ask() -> CoreAsk {
        CoreAsk(session: session, openedAt: Date().timeIntervalSince1970 - 30, summary: "Run the local tests?",
                answerable: true, request: "request-1", preview: "make test")
    }

    static func rows() -> [NotchIslandRow] {
        [NotchIslandRow(id: session, label: "review-patch", provider: "claude", activity: .waiting, ask: ask()),
         NotchIslandRow(id: "codex:working", label: "run-checks", provider: "codex", activity: .working)]
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
