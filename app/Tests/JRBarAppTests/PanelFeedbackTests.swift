import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// Feedback reaches the visible panel, palette or HUD. Long toast
/// messages wrap with or without an action button.
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

    @Test("long toast messages wrap to two lines with or without an action")
    func actionToastWraps() {
        let text = "The agent's permission hook refused that answer. Its setting has to allow answers from JR-Bar."
        let plain = height(ToastView(text: text, reduced: true))
        let short = height(ToastView(text: "Quiet ended", reduced: true))
        let shortAction = height(ToastView(text: "Quiet ended", action: (title: "Undo", run: {}), reduced: true))
        let wrapped = height(ToastView(text: text, action: (title: "Open Settings", run: {}), reduced: true))
        #expect(short == shortAction, "short feedback stays on one line")
        #expect(plain > short, "long feedback wraps without a button")
        #expect(wrapped > shortAction, "long feedback wraps beside its button")
        #expect(wrapped == plain, "both long messages use the same two-line height")
    }
}
