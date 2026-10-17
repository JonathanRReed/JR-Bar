import AppKit
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Dock action render proof", .serialized)
struct DockActionRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func refusedCloseWithAgentWarning() throws {
        let content = DockPreviewContent()
        content.appName = "Example Terminal"
        content.isRunning = true
        content.compact = true
        content.icon = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal")
        content.headerNote = "Kept the window an agent is running in"
        content.actionFailure = "Could not close 1 window. Try again."
        content.windows = [
            DockPreviewWindow(id: 1, title: "Build the project", minimized: false, fullScreen: nil,
                              frame: nil, thumbnail: nil, element: nil),
            DockPreviewWindow(id: 2, title: "Notes", minimized: true, fullScreen: nil,
                              frame: nil, thumbnail: nil, element: nil),
        ]
        for dark in [true, false] {
            let panel = DockPreviewView(content: content, actions: DockPreviewActions(content: content))
                .fixedSize()
                .background(ProofGlass(cornerRadius: content.metrics.panelRadius))
            let canvas = CGSize(width: 650, height: 330)
            let scene = ZStack {
                ProofDesktop(dark: dark)
                panel
            }.frame(width: canvas.width, height: canvas.height)
            try ProofRender.write(scene, size: canvas, name: "dock-action-failure-\(dark ? "dark" : "light")",
                                  dark: dark)
        }
    }
}
