import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Panel footer layout")
@MainActor
struct PanelFooterLayoutTests {
    @Test(arguments: [CGFloat(320), CGFloat(372)])
    func undoAndNavigationFitAtBothWidths(_ width: CGFloat) {
        let store = PanelCompositionTests.store()
        let ordinaryHeight = PanelComposition(store: store).totalHeight
        store.undoOffer = (batch: "sample-batch", at: store.now, cleared: 3)
        #expect(store.undoCountdown != nil)
        #expect(PanelComposition(store: store).totalHeight == ordinaryHeight)
        let footer = NSHostingView(rootView: PanelActionsFooter(store: store).frame(width: width))
        #expect(footer.fittingSize.width == width)
        #expect(footer.fittingSize.height == PanelComposition.footerHeight)
        store.undoOffer = nil
        let ordinary = NSHostingView(rootView: PanelActionsFooter(store: store))
        #expect(ordinary.fittingSize.height == 44)
    }

    @Test func commandZUndoesOnlyAnEligibleClearAndLeavesTextEditingAlone() async {
        let store = PanelCompositionTests.store()
        var batches: [String] = []
        store.sendUndoClear = { batch in
            batches.append(batch)
            return CoreReply(id: "sample-reply", ok: true)
        }
        #expect(!PanelController.handleUndoKey(characters: "z", flags: .command, typingInField: false, store: store))
        store.undoOffer = ("sample-batch", store.now, 3)
        #expect(!PanelController.handleUndoKey(characters: "z", flags: .command, typingInField: true, store: store))
        #expect(!PanelController.handleUndoKey(characters: "z", flags: [.command, .shift], typingInField: false, store: store))
        #expect(!PanelController.handleUndoKey(characters: "z", flags: [], typingInField: false, store: store))
        #expect(!PanelController.handleUndoKey(characters: "x", flags: .command, typingInField: false, store: store))
        #expect(PanelController.handleUndoKey(characters: "Z", flags: [.command, .capsLock], typingInField: false, store: store))
        await store.undoTask?.value
        #expect(batches == ["sample-batch"])
        #expect(store.undoCountdown == nil)
        store.undoOffer = ("expired", store.now.addingTimeInterval(-EventPolicy.undoWindow), 1)
        #expect(!PanelController.handleUndoKey(characters: "z", flags: .command, typingInField: false, store: store))
        #expect(batches == ["sample-batch"])
    }
}
