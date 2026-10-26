import AppKit
import Foundation
@testable import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Keep-awake panel header")
@MainActor
struct KeepAwakeFooterTests {
    @Test func aLiveHoldShowsInTheHeaderWithoutChangingItsHeight() throws {
        let store = PanelCompositionTests.store()
        let power = try JSONDecoder().decode(CorePower.self, from: Data(#"{"keep_awake":true,"hold":{"state":"manual","lease":{"kind":"indefinite"}}}"#.utf8))
        let bare = NSHostingView(rootView: PanelTitleBar(store: store)).fittingSize
        store.core.apply(.state(CoreState(generation: 2, power: power)))
        #expect(store.awakeHold?.symbol == "cup.and.saucer.fill")
        let held = NSHostingView(rootView: PanelTitleBar(store: store)).fittingSize
        #expect(held.height == bare.height)
        #expect(held.width <= 320)
        #expect(held.height == PanelComposition.rowHeight)
        store.core.handle(.disconnected(reason: "fixture"))
        #expect(store.awakeHold == nil)
    }

    @Test func devicePopoverControlsStayCompact() {
        let store = PanelCompositionTests.store()
        let size = NSHostingView(rootView: PanelDevicesRow(store: store)).fittingSize
        #expect(size.height > 0 && size.height <= 80)
        #expect(size.width <= 320)
    }
}
