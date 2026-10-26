import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Panel footer layout")
@MainActor
struct PanelFooterLayoutTests {
    @Test func undoAndNavigationFitAtBothWidths() {
        let store = PanelCompositionTests.store()
        store.undoOffer = (batch: "sample-batch", at: store.now, cleared: 3)
        #expect(store.undoCountdown != nil)
        let footer = NSHostingView(rootView: PanelActionsFooter(store: store))
        #expect(footer.fittingSize.width <= 320)
        #expect(footer.fittingSize.height == PanelComposition.footerHeight)
    }
}
