import AppKit
import JRBarCore
import JRBarTestSupport
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Papercut render proofs", .serialized, .temporaryDirectory, .renderProofAppearance)
struct PapercutRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test(.enabled(if: Self.enabled))
    func contextAndEvents() async throws {
        let core = CoreModel(socketPath: TestTemporaryDirectory.currentURL.appendingPathComponent("papercut.sock").path)
        let store = HistoryStore(core: core)
        let epoch = 1_792_947_600.0
        let journal = [
            CoreEvent(id: "device", kind: "device_connected", label: "Test light", at: epoch),
            CoreEvent(id: "receipt", kind: "deck_receipt", label: "Test deck", at: epoch + 30, message: "Opened History"),
            CoreEvent(id: "peer", kind: "peer_arrived", label: "Test peer", at: epoch),
        ]
        let gaps = ["transcript_not_found", "transcript_unreadable", "reading", "future_gap"]
        for dark in [false, true] {
            let view = VStack(alignment: .leading, spacing: 16) {
                Text("Context").jrbarType(.headline)
                ForEach(gaps, id: \.self) { gap in
                    UsageSessionContext(session: CoreSession(id: gap, provider: "codex", label: "Test session"),
                                        reading: nil, gap: gap, accent: .blue)
                }
                Divider()
                Text("Events").jrbarType(.headline)
                ForEach(EventLogFilter().apply(journal)) { event in EventLogRow(event: event, store: store) }
            }.padding(20)
            try await U5Proof.render(view, name: "d-context-events", width: 800, dark: dark)
            try await U5Proof.render(WhatsNewView(entries: WhatsNewCatalog.entries, tryIt: { _ in nil }, onDone: {}),
                                    name: "d-whats-new", width: WhatsNewView.width, dark: dark)
        }
    }

    @Test(.enabled(if: Self.enabled))
    func otherCodeLabels() async throws {
        let core = CoreModel(socketPath: TestTemporaryDirectory.currentURL.appendingPathComponent("papercut.sock").path)
        let defaultsName = "jrbar.test.papercut-proof.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let panel = PanelStore(core: core, draftsDefaults: defaults, screenBarShown: false)
        let studio = EffectStudioStore(core: core, defaults: defaults)
        let ask = CoreAsk(session: "test", kind: "input_required", summary: "Choose the next task")
        let session = CoreSession(id: "test", provider: "codex", label: "Test session", ask: ask)
        let row = SessionRow(session: session, pinnedAsk: ask)
        let editor = LEDSStudioModel(core: core, defaults: nil)
        editor.text = "#not-a-colour 2s"
        let fish = Fish(id: "idle", label: "Test session", providerID: "codex", state: .idling,
                        lane: 0.5, speed: 0.1, direction: 1, stateSince: .distantPast, enteredAt: .distantPast)
        let tank = AquariumView(fixture: .init(fish: [fish]))
        let why = WhyDetailModel()
        why.explanation = LightExplanation(why: "sleep_dim", kind: .sleepDim,
                                          motion: "Dim light", reason: "The display is asleep")
        for dark in [false, true] {
            let view = VStack(alignment: .leading, spacing: 16) {
                AskRow(row: row, store: panel)
                WhyDetailView(model: why)
                tank.inspectorStrip(fish)
            }.padding(20)
            try await U5Proof.render(view, name: "d-other-code-labels", width: 700, dark: dark)
            try await U5Proof.render(LEDSStudioView(store: studio, model: editor).frame(height: 740),
                                    name: "d-program-error", width: 800, dark: dark)
        }
    }

    @Test(.enabled(if: Self.enabled))
    func clusteredLabels() async throws {
        for count in [23, 50] {
            let now = Date(timeIntervalSince1970: 1_792_947_600)
            let fish = (0..<count).map { index in
                Fish(id: "fish-\(index)", label: index == 0 ? "Waiting on you" : "Test session \(index)",
                     providerID: index % 2 == 0 ? "claude" : "codex",
                     state: index == 0 ? .surfacing : index % 3 == 0 ? .idling : .swimming,
                     lane: 0.3, speed: 0.1, direction: 1, stateSince: now, enteredAt: .distantPast)
            }
            let away = AquariumAwaySummary(pearlsEarned: 120, completions: 4)
            let tank = AquariumView(fixture: .init(fish: fish, visualTime: 10, awayNotice: away))
            let view = Canvas { canvas, size in
                var layouts: [String: AquariumView.Layout] = [:]
                var candidates: [AquariumLabelLayout.Candidate] = []
                let banner = CGRect(x: 0, y: 0, width: size.width, height: 90)
                for (index, item) in fish.enumerated() {
                    var layout = AquariumView.Layout()
                    layout.x = 90 + Double(index % 8) * 85
                    layout.y = 55 + Double(index / 8) * 40
                    layout.facing = 1
                    layout.scale = 1
                    layouts[item.id] = layout
                    candidates.append(.init(id: item.id,
                        frame: tank.labelFrame(canvas: canvas, size: size, fish: item, layout: layout),
                        state: item.state, updatedAt: Double(index)))
                }
                let visible = AquariumLabelLayout.visible(candidates, in: CGRect(origin: .zero, size: size), avoiding: [banner])
                for item in fish {
                    guard let layout = layouts[item.id] else { continue }
                    tank.drawFish(canvas: &canvas, size: size, t: 10, now: now, fish: item, layout: layout,
                                  parent: nil, showLabels: false)
                }
                for item in fish where visible.contains(item.id) {
                    guard let layout = layouts[item.id] else { continue }
                    tank.drawFishLabel(canvas: &canvas, size: size, fish: item, layout: layout)
                }
            }
            .frame(width: 800, height: 440)
            .background(LinearGradient(colors: [Color(red: 0.1, green: 0.4, blue: 0.5),
                                               Color(red: 0.02, green: 0.12, blue: 0.25)],
                                       startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) { tank.awayBanner(away).padding(.top, 16) }
            try await U5Proof.render(view, name: "d-aquarium-\(count)-cluster", width: 800, dark: true)
            // The full tank also measures the real banner and suppresses chips beneath it.
            try await U5Proof.render(tank.frame(width: 800, height: 440), name: "d-aquarium-\(count)-tank", width: 800, dark: true)
        }
    }

    @Test("Alerts draw before sidebar selection in the same process", .enabled(if: Self.enabled))
    func alertsThenSidebarSelection() async throws {
        try AlertsRenderProofTests().rows()
        try await DesignFixBRenderProofTests().sidebarSelection()
    }
}
