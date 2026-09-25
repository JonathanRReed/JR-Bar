import AppKit
import Foundation
import JRBarLEDS
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Effect Studio › Moments › Lid and Finish, always on. The documents are
/// the daemon's own answers to `list_lid_presets` and `list_finish_looks`
/// for a fresh settings file, exported by `scripts/export_motion_fixtures.py`
/// into `JRBarCoreTests/Fixtures` (`tests/test_lid_presets.py` fails when
/// they fall behind the daemon).
@MainActor
@Suite struct EffectStudioMomentsTests {
    nonisolated static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "JRBarCoreTests/Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    static func lidDocument() throws -> LidTransitionList {
        try JSONDecoder().decode(LidTransitionList.self, from: fixture("list_lid_presets"))
    }

    static func finishDocument() throws -> FinishLookList {
        try JSONDecoder().decode(FinishLookList.self, from: fixture("list_finish_looks"))
    }

    /// Lays `view` out in a hosting view, off screen and never ordered in,
    /// and lets SwiftUI run until `done` holds (bounded, about 3 s).
    static func host<V: View>(_ view: V, until done: @MainActor (NSHostingView<V>) -> Bool) async -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 780, height: 900)
        for _ in 0..<150 {
            hosting.layoutSubtreeIfNeeded()
            if done(hosting) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return hosting
    }

    /// Counts the section's requests for its looks.
    final class Asks {
        var count = 0
    }

    @Test func theDaemonsLidLooksDecodeForEveryTransition() throws {
        let kinds = try Self.lidDocument().kinds
        #expect(kinds.map(\.kind) == ["open", "closed", "open_active", "closed_active"])
        #expect(kinds.map(\.label) == ["Lid opens", "Lid closes", "Lid opens while agents run",
                                       "Lid closes while agents run"])
        for transition in kinds {
            #expect(transition.presets.count == 5, "\(transition.kind)")
            let iris = transition.presets.filter { $0.shape != nil }
            #expect(iris.count == 1, "\(transition.kind) offers one Iris look")
            for look in transition.presets {
                #expect((try? LEDSProgram.parse(look.program, ledCount: 8)) != nil, "\(look.name) on the Pro")
                #expect((try? LEDSProgram.parse(look.dotProgram, ledCount: 2)) != nil, "\(look.name) on the Dot")
                #expect(look.setting.objectValue?["program"] != nil, "\(look.name) can be picked")
            }
        }
        // A fresh file plays what it shipped with; Back On It is also a look.
        let byKind = Dictionary(uniqueKeysWithValues: kinds.map { ($0.kind, $0) })
        #expect(byKind["open"]?.currentName == "As shipped")
        #expect(byKind["open_active"]?.currentName == "Back On It")
        // The Iris close's thumbnail starts lit; the strip's own program
        // closes on whatever was showing.
        let irisClose = try #require(byKind["closed"]?.presets.first { $0.shape == "iris_close" })
        #expect(irisClose.program.hasPrefix("#00E5FF 200ms cosine"))
        #expect(irisClose.dotProgram.hasPrefix("#00E5FF 200ms cosine"))
        let stored = try #require(irisClose.setting.objectValue?["program"]?.stringValue)
        #expect(!stored.hasPrefix("#00E5FF"))
    }

    @Test func theDaemonsFinishLooksDecode() throws {
        let list = try Self.finishDocument()
        #expect(list.current == "bloom")
        #expect(list.enabled)
        #expect(list.looks.map(\.style) == ["bloom", "land", "ripple"])
        for look in list.looks {
            #expect((try? LEDSProgram.parse(look.program, ledCount: 8)) != nil, "\(look.label) on the Pro")
            #expect((try? LEDSProgram.parse(look.dotProgram, ledCount: 2)) != nil, "\(look.label) on the Dot")
            #expect(FinishMomentsSection.meanings[look.style] != nil, "\(look.label) says what it does")
        }
    }

    @Test func theLidSectionDrawsARowForEachTransition() async throws {
        let store = EffectStudioStoreTests.makeStore()
        let transitions = try Self.lidDocument().kinds
        let empty = NSHostingView(rootView: LidMomentsSection(store: store).frame(width: 780)).fittingSize.height
        let drawn = NSHostingView(rootView: LidMomentsSection(store: store, seed: transitions).frame(width: 780))
            .fittingSize.height
        #expect(drawn > empty + 4 * 60, "four transitions with their thumbnails: \(empty) → \(drawn)")
    }

    /// The Finish section used to hang its load off the empty branch of an
    /// `if`, where SwiftUI never starts a task, so it never appeared in the
    /// app (the render proof passes a seed and hid it).
    @Test func theFinishSectionLoadsBeforeItHasAnythingToShow() async throws {
        let store = EffectStudioStoreTests.makeStore()
        let looks = try Self.finishDocument()
        let asks = Asks()
        let section = FinishMomentsSection(store: store, loader: {
            asks.count += 1
            return looks
        })
        .frame(width: 780)
        let hosting = await Self.host(section) { view in asks.count > 0 && view.fittingSize.height > 120 }
        #expect(asks.count > 0, "the section never asked for its looks")
        #expect(hosting.fittingSize.height > 120, "the three finishes are drawn once loaded")
    }
}
