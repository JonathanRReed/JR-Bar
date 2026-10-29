import JRBarTestSupport
import AppKit
import JRBarCore
import Testing
import SwiftUI
@testable import JRBarApp

@Suite("Dock preview target display sizing", .renderProofAppearance)
@MainActor
struct DockPreviewSizingTests {
    @Test func narrowSecondaryDisplayContainsPreviewAtEveryDockEdge() {
        let secondary = CGRect(x: -480, y: 240, width: 480, height: 640)
        let place = DockPlacement(gap: 8, coversLabel: false)
        let cases: [(DockEdge, CGRect)] = [
            (.bottom, CGRect(x: -260, y: 240, width: 48, height: 48)),
            (.left, CGRect(x: -480, y: 500, width: 48, height: 48)),
            (.right, CGRect(x: -48, y: 500, width: 48, height: 48)),
        ]
        for (edge, tile) in cases {
            let budget = place.availableSize(anchor: tile, edge: edge, screen: secondary,
                                             title: "Synthetic App")
            let frame = place.frame(anchor: tile, edge: edge, size: budget, screen: secondary,
                                    title: "Synthetic App")
            #expect(secondary.contains(frame))
            #expect(budget.width <= secondary.width - 40)
            #expect(budget.height <= secondary.height - 40)
            switch edge {
            case .bottom: #expect(frame.minY > tile.maxY)
            case .left: #expect(frame.minX > tile.maxX)
            case .right: #expect(frame.maxX < tile.minX)
            }
        }
    }

    @Test func controlsLargerThanDisplayRemainInScrollableDocument() throws {
        let content = DockPreviewContent()
        content.appName = "Synthetic App"
        content.isRunning = true
        content.compact = true
        content.windows = (0..<20).map { index in
            DockPreviewWindow(id: index, title: "Synthetic Window \(index)", minimized: false,
                              fullScreen: false, frame: nil, thumbnail: nil, element: nil)
        }
        let panel = DockPreviewPanel(content: content)
        defer { panel.close() }
        let budget = CGSize(width: 220, height: 120)
        let size = panel.fittingSize(maximumSize: budget)
        #expect(size.width <= budget.width)
        #expect(size.height <= budget.height)
        Self.layout(panel, size: size)
        let scroll = try #require(Self.scrollView(in: panel.contentView))
        let document = try #require(scroll.documentView)
        #expect(document.frame.width > size.width)
        #expect(document.frame.height > size.height)
        #expect(scroll.hasHorizontalScroller)
        #expect(scroll.hasVerticalScroller)
        #expect(scroll.contentView.bounds.width <= budget.width)
        #expect(scroll.contentView.bounds.height <= budget.height)
        let farCorner = CGPoint(x: document.frame.width - scroll.contentSize.width,
                                y: document.frame.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: farCorner)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(abs(scroll.documentVisibleRect.maxX - document.frame.width) <= 1)
        #expect(abs(scroll.documentVisibleRect.maxY - document.frame.height) <= 1)

        // Retargeting reuses the native panel but restores the header.
        content.appName = "Another Synthetic App"
        panel.resetScrollPosition()
        #expect(scroll.documentVisibleRect.minX <= 1)
        if document.isFlipped {
            #expect(scroll.documentVisibleRect.minY <= 1)
        } else {
            #expect(abs(scroll.documentVisibleRect.maxY - document.frame.height) <= 1)
        }
        // The layout stays at its natural size, including minimum-width
        // controls. The viewport clips and scrolls instead of scaling it.
        let naturalSize = document.frame.size
        let larger = panel.fittingSize(maximumSize: CGSize(width: 440, height: 480))
        Self.layout(panel, size: larger)
        #expect(document.frame.size == naturalSize)
        #expect(!panel.isVisible)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func offscreenNativeViewportProofs() throws {
        let content = DockPreviewContent()
        content.appName = "Synthetic App"
        content.isRunning = true
        content.compact = true
        content.windows = (0..<12).map { index in
            DockPreviewWindow(id: index, title: "Synthetic Window \(index + 1)", minimized: false,
                              fullScreen: false, frame: nil, thumbnail: nil, element: nil)
        }
        let panel = DockPreviewPanel(content: content)
        panel.appearance = NSAppearance(named: .aqua)
        defer { panel.close() }
        for (name, budget) in [("normal", CGSize(width: 720, height: 600)),
                               ("narrow", CGSize(width: 220, height: 160))] {
            let size = panel.fittingSize(maximumSize: budget)
            Self.layout(panel, size: size)
            panel.resetScrollPosition()
            let viewport = try #require(Self.scrollView(in: panel.contentView))
            try ProofRender.write(Color(nsColor: .windowBackgroundColor), size: size,
                                  name: "dock-native-viewport-\(name)", dark: false, overlay: viewport)
        }
        #expect(!panel.isVisible)
    }

    private static func layout(_ panel: DockPreviewPanel, size: CGSize) {
        panel.setContentSize(size)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = scrollView(in: child) { return scroll }
        }
        return nil
    }
}
