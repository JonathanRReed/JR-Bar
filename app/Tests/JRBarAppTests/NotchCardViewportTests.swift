import AppKit
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Notch card viewport")
struct NotchCardViewportTests {
    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = scrollView(in: child) { return scroll }
        }
        return nil
    }

    @Test("the card viewport stays at its full layout size while the silhouette grows")
    func viewportDoesNotResizeWithSilhouette() throws {
        let core = CoreModel()
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.cardModel.pinned = true
        let width = toy.expandedCardWidth
        let height: CGFloat = 360
        toy.stage.cardWidth = width
        toy.stage.cardHeight = height
        toy.stage.setOpenness(0.5, expanded: true)
        toy.stage.showContent(level: 0.6, expanded: true)
        let host = NSHostingView(rootView: NotchIslandView(toy: toy))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: width + 40, height: height + 40)
        let window = NSWindow(contentRect: CGRect(x: 5000, y: 5000, width: width + 40, height: height + 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close(); withExtendedLifetime(store) {} }
        for shape in [CGSize(width: 185, height: 60), CGSize(width: 260, height: 160),
                      CGSize(width: width, height: height)] {
            toy.stage.shape = CGRect(x: (host.bounds.width - shape.width) / 2, y: 0,
                                     width: shape.width, height: shape.height)
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            let scroll = try #require(scrollView(in: host), "the actual card scroll view was not hosted")
            #expect(abs(scroll.contentView.bounds.width - width) < 1,
                    "the card must not be clipped to a moving viewport's left edge")
            #expect(abs(scroll.contentView.bounds.height - (height - toy.cardTopPad)) < 1,
                    "the silhouette clips the card; its scroll viewport must remain stable")
        }
    }
}
