import AppKit
import Foundation
@testable import JRBarCore
import Observation
import SwiftUI
import Testing
@testable import JRBarApp

/// The Agent Overview card reads a snapshot of the daemon — whether it
/// is live, and which providers report — written only when it changes,
/// so a `state` push redraws the card only when the card would change;
/// and the rules table builds one of its two layouts.
@Suite("Agent Overview snapshot")
@MainActor
struct AgentUtilitySnapshotTests {
    // MARK: Agent Overview

    private static func state(_ sessions: [CoreSession], hooks: [String: String]) -> CoreMessage {
        let health: JSONValue = .object(["hooks": .object(hooks.mapValues { .string($0) })])
        return .state(CoreState(sessions: sessions, health: health))
    }

    @Test("the snapshot names the providers with hooks or a session, and whether the monitor is live")
    func agentSnapshot() {
        let core = CoreModel()
        core.handle(.connected)
        core.apply(Self.state([CoreSession(id: "s1", provider: "codex")], hooks: ["claude": "ok", "gemini": "missing"]))
        let snapshot = AgentUtility.snapshot(of: core)
        #expect(snapshot.live)
        #expect(snapshot.reporting == ["claude", "codex"])
    }

    @Test("a state push that changes neither the providers nor the connection fires no observation")
    func agentSnapshotQuiet() {
        let core = CoreModel()
        core.handle(.connected)
        core.apply(Self.state([CoreSession(id: "s1", provider: "codex")], hooks: ["claude": "ok"]))
        let utility = AgentUtility(core: core)
        var stored = AgentOverviewSettings()
        utility.settings = { stored }
        utility.onSettingsChange = { stored = $0 }
        utility.refreshSnapshot()
        #expect(utility.alertProviders == ["claude", "codex"])

        let fired = ObservationFlag()
        withObservationTracking {
            _ = utility.alertProviders
            _ = utility.status
        } onChange: {
            fired.set()
        }
        // A new generation, a session moved on: the same providers.
        core.apply(Self.state([CoreSession(id: "s1", provider: "codex", updatedAt: 5)], hooks: ["claude": "ok"]))
        utility.refreshSnapshot()
        #expect(!fired.value, "the card and its chip stay put")

        core.apply(Self.state([CoreSession(id: "s1", provider: "codex"), CoreSession(id: "s2", provider: "grok")],
                              hooks: ["claude": "ok"]))
        utility.refreshSnapshot()
        #expect(fired.value, "a new provider reaches the card")
        #expect(utility.alertProviders.contains("grok"))
    }

    @Test("the chip follows the connection through the snapshot")
    func agentStatus() {
        let core = CoreModel()
        let utility = AgentUtility(core: core)
        var stored = AgentOverviewSettings()
        stored.enabled = true
        utility.settings = { stored }
        #expect(utility.status == .paused("Monitor not connected"))
        core.handle(.connected)
        core.apply(.state(CoreState()))
        utility.refreshSnapshot()
        #expect(utility.status == .on)
    }

    @Test("the rules table falls back to the stacked rows only when its measured width does not fit")
    func rulesLayoutChoice() {
        typealias Choice = WidestThatFits<EmptyView, EmptyView>
        #expect(!Choice.fallsBack(ideal: nil, offered: 400, current: true), "not measured yet: the table")
        #expect(!Choice.fallsBack(ideal: 380, offered: 400, current: true))
        #expect(Choice.fallsBack(ideal: 420, offered: 400, current: true))
        #expect(!Choice.fallsBack(ideal: 420, offered: 400, current: false), "new providers: measure again")
        #expect(!Choice.fallsBack(ideal: 420, offered: nil, current: true))
    }

    @Test("a rules grid selects stacked rows when its fixed columns exceed the available width",
          arguments: [CGFloat(360), 430, 900])
    func rulesGridRespectsConstrainedWidth(width: CGFloat) {
        func columns() -> some View {
            Grid(horizontalSpacing: 12) {
                GridRow {
                    ForEach(0..<6) { _ in Text("Escalates to").fixedSize() }
                }
            }
            .frame(height: 20)
        }
        let chosen = NSHostingView(rootView: WidestThatFits(key: 1) {
            columns()
        } fallback: {
            Color.blue.frame(height: 40)
        }.frame(width: width))
        chosen.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        for _ in 0..<8 {
            chosen.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date())
        }
        #expect(chosen.fittingSize.height == (width < 600 ? 40 : 20),
                "Fixed columns must not widen the offered space at \(width) points")
    }

    @Test("provider changes and repeated resizing keep the rules layout responsive")
    func rulesGridRemeasuresAfterProviderChanges() {
        func card(width: CGFloat, key: Int) -> some View {
            WidestThatFits(key: key) {
                Grid(horizontalSpacing: 12) {
                    GridRow {
                        ForEach(0..<6) { _ in Text("Escalates to").fixedSize() }
                    }
                }
                .frame(height: 20)
            } fallback: {
                Color.blue.frame(height: 40)
            }
            .frame(width: width)
        }
        let chosen = NSHostingView(rootView: card(width: 900, key: 1))
        for (width, key, expectedHeight) in [(900.0, 1, 20.0), (900, 2, 20),
                                           (360, 2, 40), (900, 2, 20), (360, 3, 40)] {
            chosen.rootView = card(width: width, key: key)
            chosen.frame = CGRect(x: 0, y: 0, width: width, height: 100)
            for _ in 0..<8 {
                chosen.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date())
            }
            #expect(abs(chosen.fittingSize.height - CGFloat(expectedHeight)) < 0.5,
                    "Width \(width), provider key \(key)")
        }
    }

    @Test("the rules card builds one layout, and picks as ViewThatFits did")
    func rulesLayoutMatchesViewThatFits() {
        for width in [CGFloat(900), 360] {
            let chosen = NSHostingView(rootView: WidestThatFits(key: 1) {
                Color.red.frame(idealWidth: 600, maxWidth: .infinity).frame(height: 20)
            } fallback: {
                Color.blue.frame(height: 40)
            }.frame(width: width))
            let reference = NSHostingView(rootView: ViewThatFits(in: .horizontal) {
                Color.red.frame(idealWidth: 600, maxWidth: .infinity).frame(height: 20)
                Color.blue.frame(height: 40)
            }.frame(width: width))
            for view in [chosen, reference] {
                view.frame = CGRect(x: 0, y: 0, width: width, height: 100)
                for _ in 0..<3 {
                    view.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date())
                }
            }
            #expect(chosen.fittingSize.height == reference.fittingSize.height, "at \(width) points")
        }
    }
}

/// Set from an observation's change callback, which may run anywhere.
private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    func set() {
        lock.lock()
        fired = true
        lock.unlock()
    }
}
