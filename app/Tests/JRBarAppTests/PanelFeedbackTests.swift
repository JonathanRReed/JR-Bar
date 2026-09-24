import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// Feedback you can see: a line that did not come from a panel click is
/// said where someone will read it, and a toast with a button wraps
/// rather than cut its reason off.
@Suite("Panel feedback")
@MainActor
struct PanelFeedbackTests {
    @Test("a closed panel's feedback goes to the HUD unless a palette verb is listening")
    func routes() {
        #expect(PanelStore.feedbackRoute(panelOpen: true, paletteListening: false) == .toast)
        #expect(PanelStore.feedbackRoute(panelOpen: false, paletteListening: true) == .toast)
        #expect(PanelStore.feedbackRoute(panelOpen: true, paletteListening: true) == .toast)
        #expect(PanelStore.feedbackRoute(panelOpen: false, paletteListening: false) == .hud)
    }

    private func height(_ toast: ToastView) -> CGFloat {
        NSHostingView(rootView: toast.frame(width: CGFloat(PanelLayout.width))).fittingSize.height
    }

    @Test("a long toast with a button wraps to a second line; one without stays on one")
    func actionToastWraps() {
        let text = "The agent's permission hook refused that answer — its setting has to allow answers from JR-Bar"
        let plain = height(ToastView(text: text, reduced: true))
        let short = height(ToastView(text: "Quiet ended", action: (title: "Undo", run: {}), reduced: true))
        let wrapped = height(ToastView(text: text, action: (title: "Open Settings", run: {}), reduced: true))
        #expect(plain == short, "one line either way")
        #expect(wrapped > plain, "the reason wraps rather than truncate: \(wrapped) vs \(plain)")
    }
}
