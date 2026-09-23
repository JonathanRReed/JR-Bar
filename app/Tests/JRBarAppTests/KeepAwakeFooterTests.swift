import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// The panel's keep-awake line: words while a hold stands, nothing while
/// none does or the monitor is away, and never a point of the panel's
/// fixed geometry — it lies over the Devices header's empty trailing slot.
@Suite("Keep-awake panel line")
@MainActor
struct KeepAwakeFooterTests {
    private func power(_ hold: String) throws -> CorePower {
        try JSONDecoder().decode(CorePower.self, from: Data(#"{"keep_awake":true,"hold":\#(hold)}"#.utf8))
    }

    private func store(power: String?) throws -> PanelStore {
        let core = CoreModel()
        var fields = [#""t":"state","v":1,"generation":1,"aggregate":{},"sessions":[],"asks":[],"devices":[]"#]
        if let power { fields.append(#""power":\#(power)"#) }
        core.apply(try CoreCodec.decode(frame: Data("{\(fields.joined(separator: ","))}".utf8)))
        return PanelStore(core: core, screenBarShown: false)
    }

    @Test func aHoldShowsItsWordsAndNoHoldShowsNothing() throws {
        let lease = try power(#"{"state":"manual","lease":{"kind":"indefinite"}}"#)
        #expect(NSHostingView(rootView: KeepAwakeFooter(power: lease)).fittingSize.width > 40)
        let agents = try power(#"{"state":"agents","agents":2}"#)
        #expect(NSHostingView(rootView: KeepAwakeFooter(power: agents)).fittingSize.width > 40)
        #expect(NSHostingView(rootView: KeepAwakeFooter(power: try power(#"{"state":"off"}"#))).fittingSize == .zero)
        #expect(NSHostingView(rootView: KeepAwakeFooter(power: nil)).fittingSize == .zero,
                "the monitor away: no stale hold named")
    }

    @Test func theLineTakesNoRoomInThePanel() throws {
        let width = CGFloat(PanelLayout.width)
        let until = Date().timeIntervalSince1970 + 5400
        let lease = try power(#"{"state":"manual","lease":{"kind":"duration","until":\#(until)}}"#)
        let proposal = CGSize(width: width, height: 400)
        // The line is really drawn — a comparison of two bare headers
        // would prove nothing.
        let line = NSHostingView(rootView: KeepAwakeFooter(power: lease)).fittingSize
        #expect(line.width > 0)
        // The Devices header as the section draws it while the monitor is
        // live (no "from files" word), with the line laid over it and
        // without: the same size, so no row moves.
        let held = NSHostingController(rootView: SectionLabel(text: "Devices")
            .overlay(alignment: .bottomTrailing) { KeepAwakeFooter(power: lease) }).sizeThatFits(in: proposal)
        let bare = NSHostingController(rootView: SectionLabel(text: "Devices")).sizeThatFits(in: proposal)
        #expect(held == bare, "an overlay: no row moves, the computed height holds")
        // It sits clear of the header's own word.
        let word = NSHostingView(rootView: SectionLabel(text: "Devices")).fittingSize
        #expect(word.width + line.width <= width)
        // And the section keeps the panel's computed height.
        let section = NSHostingController(rootView: DevicesSection(store: try store(power: nil)))
            .sizeThatFits(in: proposal)
        #expect(section.height == CGFloat(PanelLayout.devicesHeight))
    }
}
