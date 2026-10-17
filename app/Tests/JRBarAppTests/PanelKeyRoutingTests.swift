import AppKit
import Testing
@testable import JRBarApp

/// The keys the panel leaves to a reply field being typed into. Return
/// sends the reply and the arrows move the caret; neither may open the
/// selected session or move the card selection behind the field.
@Suite("Panel keys while typing")
struct PanelKeyRoutingTests {
    @Test("Return, the arrows and Tab stay with the field being typed into")
    func fieldKeepsItsKeys() {
        for code: UInt16 in [36, 76, 125, 126, 48] {
            #expect(PanelController.fieldKeepsKey(keyCode: code, flags: [], typingInField: true), "key \(code)")
        }
        #expect(PanelController.fieldKeepsKey(keyCode: 48, flags: [.shift], typingInField: true))
        #expect(PanelController.fieldKeepsKey(keyCode: 51, flags: [.command], typingInField: true), "⌘⌫ deletes a line there")
    }

    @Test("with no field, the panel's own keys are unchanged")
    func panelKeepsItsKeys() {
        for code: UInt16 in [36, 76, 125, 126, 48, 51, 53] {
            #expect(!PanelController.fieldKeepsKey(keyCode: code, flags: [], typingInField: false), "key \(code)")
        }
    }

    @Test("Esc still closes the panel, and a plain Delete is the field's own already")
    func escapeAndDelete() {
        #expect(!PanelController.fieldKeepsKey(keyCode: 53, flags: [], typingInField: true))
        #expect(!PanelController.fieldKeepsKey(keyCode: 51, flags: [], typingInField: true))
    }
}
