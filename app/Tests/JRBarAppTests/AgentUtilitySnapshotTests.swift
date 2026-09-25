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
        var stored = AgentOrganizerSettings()
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
        var stored = AgentOrganizerSettings()
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
