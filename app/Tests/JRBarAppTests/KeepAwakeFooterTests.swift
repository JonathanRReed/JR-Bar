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
        let held = try store(power: #"{"keep_awake":true,"hold":{"state":"manual","lease":{"kind":"duration","until":\#(until)}}}"#)
        let bare = try store(power: nil)
        let proposal = CGSize(width: width, height: 400)
        let heldSize = NSHostingController(rootView: DevicesSection(store: held)).sizeThatFits(in: proposal)
        let bareSize = NSHostingController(rootView: DevicesSection(store: bare)).sizeThatFits(in: proposal)
        #expect(heldSize == bareSize, "an overlay: no row moves, the computed height holds")
        #expect(heldSize.height == CGFloat(PanelLayout.devicesHeight))
    }
}
