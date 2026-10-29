import AppKit
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Factory sheet termination", .serialized)
struct FactorySheetTerminationTests {
    @Test("the Factory sheet permits quit and restores its window policy when removed")
    func factorySheetAllowsQuit() {
        let model = ProviderCredentialEditorModel(provider: "factory", instance: "default", account: "api-key",
            available: false, save: { _ in }, remove: {})
        let hosting = NSHostingView(rootView: ProviderCredentialEditor(
            model: model, dismiss: {}))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 500, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.preventsApplicationTerminationWhenModal = true
        defer { window.contentView = nil; window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        #expect(!window.isVisible)
        #expect(!window.preventsApplicationTerminationWhenModal,
                "The connection sheet must not veto application termination")
        window.contentView = nil
        #expect(window.preventsApplicationTerminationWhenModal)
    }

    @Test("replacement probes preserve the policy until the last owner leaves", arguments: [false, true])
    func overlappingOwners(original: Bool) {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.preventsApplicationTerminationWhenModal = original
        let content = NSView(frame: .zero)
        window.contentView = content
        defer { window.contentView = nil; window.close() }
        let first = NonblockingSheetWindow.Anchor(frame: .zero)
        let replacement = NonblockingSheetWindow.Anchor(frame: .zero)
        content.addSubview(first)
        content.addSubview(replacement)
        #expect(!window.preventsApplicationTerminationWhenModal)
        first.removeFromSuperview()
        first.releaseWindow()
        #expect(!window.preventsApplicationTerminationWhenModal)
        replacement.removeFromSuperview()
        replacement.releaseWindow()
        #expect(window.preventsApplicationTerminationWhenModal == original)
    }

    @Test("moving a probe restores each window's own policy")
    func transfersBetweenWindows() {
        let first = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        first.preventsApplicationTerminationWhenModal = true
        second.preventsApplicationTerminationWhenModal = false
        let firstContent = NSView(frame: .zero)
        let secondContent = NSView(frame: .zero)
        first.contentView = firstContent
        second.contentView = secondContent
        defer {
            first.contentView = nil
            second.contentView = nil
            first.close()
            second.close()
        }
        let anchor = NonblockingSheetWindow.Anchor(frame: .zero)
        firstContent.addSubview(anchor)
        #expect(!first.preventsApplicationTerminationWhenModal)
        #expect(!second.preventsApplicationTerminationWhenModal)
        secondContent.addSubview(anchor)
        anchor.synchronizeWindow()
        #expect(first.preventsApplicationTerminationWhenModal)
        #expect(!second.preventsApplicationTerminationWhenModal)
        anchor.removeFromSuperview()
        #expect(!second.preventsApplicationTerminationWhenModal)
    }
}
