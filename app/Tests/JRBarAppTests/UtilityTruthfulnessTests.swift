import Foundation
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Utility state truthfulness")
struct UtilityTruthfulnessTests {
    @Test("folder summaries distinguish blocked and failed reads from ready counts")
    func folderSummaries() {
        #expect(DockPreviewView.folderSubtitle(state: .loading, count: 0) == "Folder")
        #expect(DockPreviewView.folderSubtitle(state: .denied, count: 0) == "No access")
        #expect(DockPreviewView.folderSubtitle(state: .failed, count: 0) == "Read failed")
        #expect(DockPreviewView.folderSubtitle(state: .ready, count: 0) == "0 items")
        #expect(DockPreviewView.folderSubtitle(state: .ready, count: 1) == "1 item")
        #expect(DockPreviewView.folderSubtitle(state: .ready, count: 3) == "3 items")
    }

    @Test("external provider notes require both installation and a running app")
    func externalProviderNotes() {
        for name in ["Alcove", "Boring Notch"] {
            for running in [false, true] {
                #expect(NotchExternalProviderNote.text(installed: false, running: running, name: name)
                        == "\(name) isn't installed.")
            }
            #expect(NotchExternalProviderNote.text(installed: true, running: false, name: name)
                    == "\(name) isn't running. Open it to draw the island.")
            #expect(NotchExternalProviderNote.text(installed: true, running: true, name: name)
                    == "\(name) is running and draws the island.")
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func stoppedProviderNotesKeepAnExplicitOpenButton() throws {
        var opens = 0
        for name in ["Alcove", "Boring Notch"] {
            try WindowsRenderProofTests.write("utility-stopped-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                                              size: CGSize(width: 560, height: 130)) {
                NotchExternalProviderNote(installed: true, running: false, name: name,
                                          link: URL(string: "https://example.invalid")!, open: { opens += 1 })
                    .padding(24)
            }
        }
        #expect(opens == 0)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func blockedFolderSummariesWithRecoveryControls() throws {
        var retries = 0
        for state in [DockFolderState.denied, .failed] {
            let content = DockPreviewContent()
            content.appName = "Documents"
            content.folderURL = URL(fileURLWithPath: "/synthetic/Documents")
            content.folderState = state
            var actions = DockPreviewActions(content: content)
            actions.onRetryFolder = { retries += 1 }
            let label = DockPreviewView.folderSubtitle(state: state, count: 0)
            try WindowsRenderProofTests.write("utility-folder-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))",
                                              size: CGSize(width: 560, height: 250)) {
                DockPreviewView(content: content, actions: actions)
                    .padding(12)
            }
        }
        #expect(retries == 0)
    }
}
