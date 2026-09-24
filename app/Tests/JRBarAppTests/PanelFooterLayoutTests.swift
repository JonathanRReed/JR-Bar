import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// The footer fits the panel: with every optional piece showing — the
/// awake mark, a quiet label and the Undo countdown — the row the footer
/// falls back to is no wider than `PanelLayout.width`, where the panel's
/// edge would clip it; an everyday footer keeps the roomier row.
@Suite("Panel footer layout")
@MainActor
struct PanelFooterLayoutTests {
    /// What the row has to fit in: the panel less the footer's padding.
    private static let room = CGFloat(PanelLayout.width) - 8 * 2

    private func makeStore(power: String?, focus: String?) throws -> PanelStore {
        let core = CoreModel()
        var fields = [#""t":"state","v":1,"generation":1,"aggregate":{},"sessions":[],"asks":[],"devices":[]"#]
        if let power { fields.append(#""power":\#(power)"#) }
        if let focus { fields.append(#""focus":\#(focus)"#) }
        core.apply(try CoreCodec.decode(frame: Data("{\(fields.joined(separator: ","))}".utf8)))
        return PanelStore(core: core, screenBarShown: false)
    }

    private func rowWidth(_ store: PanelStore, compact: Bool) -> CGFloat {
        NSHostingView(rootView: PanelFooterRow(store: store, compact: compact)).fittingSize.width
    }

    @Test("with the awake mark, a quiet label and the Undo countdown all showing, the footer fits")
    func everythingShowingFits() throws {
        let until = Date().timeIntervalSince1970 + 23 * 3600
        let store = try makeStore(power: #"{"keep_awake":true,"closed_lid":{"holding":true}}"#,
                                  focus: #"{"mode":"asks_only","source":"override","until":\#(until)}"#)
        store.now = Date()
        store.undoOffer = (batch: "b-1", at: store.now, cleared: 3)
        #expect(store.awakeHold != nil)
        #expect(store.quietLabel == "Asks only 23h")
        #expect(store.undoCountdown != nil)
        let compact = rowWidth(store, compact: true)
        #expect(compact <= Self.room, "the tightest row, \(compact) pt, overflows \(Self.room) pt")
        #expect(rowWidth(store, compact: false) > compact, "compact is the tighter row")
    }

    @Test("an everyday footer — the awake mark, nothing else — keeps the roomier row")
    func everydayKeepsTheRoomierRow() throws {
        let store = try makeStore(power: #"{"keep_awake":true}"#, focus: nil)
        #expect(store.awakeHold != nil)
        let full = rowWidth(store, compact: false)
        #expect(full <= Self.room, "the everyday row, \(full) pt, overflows \(Self.room) pt")
    }
}
