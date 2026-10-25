import AppKit
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Screen Bar peek anchor lifetime")
struct ScreenBarPeekAnchorTests {
    @Test("moving an unchanged menu reuses its measured content, and content changes refit it")
    func anchorMovesReuseContentSize() throws {
        let peek = ScreenBarPeek()
        var ear = CGRect(x: 5180, y: 5950, width: 32, height: 32)
        var measurements = 0
        var screen = CGRect(x: 4000, y: 4000, width: 2000, height: 2000)
        peek.anchor = {
            ScreenBarPeekAnchor(ear: ear, band: nil, screen: screen)
        }
        peek.presentPanel = { _, _ in }
        peek.measureNaturalSize = { probe in
            measurements += 1
            probe.layoutSubtreeIfNeeded()
            return probe.fittingSize
        }
        let panel = peek.makePanel()
        defer { peek.hide(); panel.orderOut(nil) }
        peek.show(pinned: false)
        let original = panel.frame
        for _ in 0..<12 {
            ear.origin.y -= 2
            peek.relayout()
        }
        #expect(measurements == 1)
        #expect(panel.frame.height == original.height)
        #expect(panel.frame.maxY == original.maxY - 24)
        peek.model.awake = .init(symbol: "cup.and.saucer.fill", text: "Held awake while work finishes")
        peek.relayout()
        #expect(measurements == 2)
        #expect(panel.frame.height > original.height)
        peek.model.awake = .init(symbol: "cup.and.saucer.fill", text: "Held awake while work finishes")
        peek.relayout()
        #expect(measurements == 2)
        peek.model.width += 20
        peek.relayout()
        #expect(measurements == 3)
        #expect(panel.frame.width == peek.model.width)
        peek.model.awake = .init(symbol: "cup.and.saucer.fill",
            text: Array(repeating: "Held awake", count: 20).joined(separator: "\n"))
        peek.relayout()
        let hosting = try #require(panel.contentView as? NSHostingView<ScreenBarPeekView>)
        #expect(measurements == 4 && hosting.rootView.viewportHeight == nil)
        screen = CGRect(x: 4000, y: 5800, width: 2000, height: 200)
        peek.relayout()
        #expect(measurements == 4 && hosting.rootView.viewportHeight != nil)
        screen = CGRect(x: 4000, y: 4000, width: 2000, height: 2000)
        peek.relayout()
        #expect(measurements == 4 && hosting.rootView.viewportHeight == nil)
    }

    @Test("only an automatic unpinned dismissal at the same anchor can resume")
    func hoverResumeAuthorization() {
        let peek = ScreenBarPeek()
        var visible = false
        peek.panelIsVisible = { _ in visible }
        var ear = CGRect(x: 5100, y: 5950, width: 32, height: 32)
        peek.anchor = {
            ScreenBarPeekAnchor(ear: ear,
                               band: CGRect(x: 5000, y: 5940, width: 200, height: 2),
                               screen: CGRect(x: 4000, y: 4000, width: 2000, height: 2000))
        }
        peek.presentPanel = { panel, _ in visible = true }
        let panel = peek.makePanel()
        defer { peek.hide(); panel.orderOut(nil); visible = false }
        peek.show(pinned: false)
        peek.hide(resumable: true)
        visible = true
        #expect(peek.canResumeHover && peek.hoverFrame != nil)
        #expect(peek.frame == nil)
        ear.origin.x += 10
        #expect(!peek.canResumeHover && peek.hoverFrame == nil)
        ear.origin.x -= 10
        peek.hide()
        #expect(!peek.canResumeHover && peek.hoverFrame == nil)
        peek.show(pinned: true)
        peek.hide(resumable: true)
        visible = true
        #expect(!peek.canResumeHover)
        peek.show(pinned: false)
        peek.hide(resumable: true)
        panel.orderOut(nil); visible = false
        #expect(!peek.canResumeHover && peek.hoverFrame == nil)
    }

    @Test("reopening a still-visible fading menu preserves its current alpha")
    func warmShowDoesNotResetAlpha() {
        let peek = ScreenBarPeek()
        var visible = false
        peek.panelIsVisible = { _ in visible }
        peek.anchor = {
            ScreenBarPeekAnchor(ear: CGRect(x: 5100, y: 5950, width: 32, height: 32),
                               band: CGRect(x: 5000, y: 5940, width: 200, height: 2),
                               screen: CGRect(x: 4000, y: 4000, width: 2000, height: 2000))
        }
        var starts: [CGFloat?] = []
        peek.presentPanel = { panel, start in
            starts.append(start)
            if let start { panel.alphaValue = start }
            visible = true
        }
        let panel = peek.makePanel()
        defer { peek.hide(); panel.orderOut(nil); visible = false }
        peek.show(pinned: false)
        #expect(starts.count == 1 && starts[0] == 0)
        peek.hide()
        visible = true
        #expect(visible && !panel.isVisible)
        panel.alphaValue = 0.45
        peek.show(pinned: false)
        #expect(starts.count == 2 && starts[1] == nil)
        #expect(panel.alphaValue == 0.45)
        #expect(!panel.ignoresMouseEvents)
        peek.hide()
        panel.orderOut(nil); visible = false
        peek.show(pinned: false)
        #expect(starts.count == 3 && starts[2] == 0)
    }
    @Test("oversized attached menu content scrolls and later returns to natural sizing")
    func boundedPopupScrolls() throws {
        let peek = ScreenBarPeek()
        peek.anchor = {
            ScreenBarPeekAnchor(ear: CGRect(x: 5180, y: 4150, width: 32, height: 32),
                               band: CGRect(x: 5070, y: 4020, width: 200, height: 2),
                               screen: CGRect(x: 5000, y: 4000, width: 300, height: 200))
        }
        peek.model.awake = .init(symbol: "cup.and.saucer.fill", text: Array(repeating: "Held awake", count: 20).joined(separator: "\n"))
        peek.model.width = ScreenBarPeekLayout.wordsWidth + 2 * ScreenBarPeekLayout.padding
        let panel = peek.makePanel()
        defer { peek.hide(); panel.orderOut(nil) }
        peek.show(pinned: false)
        let hosting = try #require(panel.contentView as? NSHostingView<ScreenBarPeekView>)
        #expect(panel.frame.height == 144)
        #expect(hosting.rootView.viewportHeight == panel.frame.height)
        #expect(panel.frame.minY >= 4006 && panel.frame.maxY <= 4150)
        if NotchSurfaceRenderProofTests.enabled {
            try ProofRender.write(hosting.rootView, size: panel.frame.size,
                                  name: "menu-child-scroll-viewport", settle: 0)
        }
        peek.model.awake = .init(symbol: "cup.and.saucer.fill", text: "Held awake")
        peek.relayout()
        #expect(hosting.rootView.viewportHeight == nil)
        #expect(panel.frame.height < 144)
    }
    @Test("a reused popup measures current content before it is presented")
    func currentContentAtPresentation() throws {
        let peek = ScreenBarPeek()
        peek.anchor = {
            ScreenBarPeekAnchor(ear: CGRect(x: 5100, y: 5950, width: 32, height: 32),
                               band: CGRect(x: 5000, y: 5940, width: 200, height: 2),
                               screen: CGRect(x: 4000, y: 4000, width: 2000, height: 2000))
        }
        let panel = peek.makePanel()
        defer { peek.hide(); panel.orderOut(nil) }
        let oldHosting = try #require(panel.contentView as? NSHostingView<ScreenBarPeekView>)
        _ = oldHosting.fittingSize
        let empty = NSHostingView(rootView: ScreenBarPeekView(model: ScreenBarPeekModel()))
        empty.sizingOptions = [.intrinsicContentSize]
        empty.layoutSubtreeIfNeeded()
        let emptySize = empty.fittingSize
        peek.model.awake = .init(symbol: "cup.and.saucer.fill", text: "Held awake while work finishes")
        peek.model.width = ScreenBarPeekLayout.width(tileWidths: [], hasWords: true)
        let fresh = NSHostingView(rootView: ScreenBarPeekView(model: peek.model))
        fresh.sizingOptions = [.intrinsicContentSize]
        fresh.layoutSubtreeIfNeeded()
        let expected = fresh.fittingSize
        #expect(emptySize.height >= 2 * ScreenBarPeekLayout.padding)
        #expect(expected.height > emptySize.height)
        peek.show(pinned: false)
        #expect(abs(panel.frame.height - expected.height) < 0.5)
        if NotchSurfaceRenderProofTests.enabled {
            try ProofRender.write(ScreenBarPeekView(model: peek.model), size: expected,
                                  name: "menu-peek-measured-content", settle: 0)
        }
        #expect(panel.frame.width == peek.model.width)
        peek.model.awake = nil
        peek.model.width = ScreenBarPeekLayout.width(tileWidths: [], hasWords: false)
        peek.relayout()
        #expect(abs(panel.frame.height - emptySize.height) < 0.5)
        peek.hide()
        peek.model.awake = .init(symbol: "cup.and.saucer.fill", text: "Held awake while work finishes")
        peek.model.width = ScreenBarPeekLayout.width(tileWidths: [], hasWords: true)
        peek.show(pinned: false)
        #expect(abs(panel.frame.height - expected.height) < 0.5)
        peek.model.awake = nil
        let item = MenuBarItem(id: "example", ownerPID: 0, ownerName: "Example",
                               bounds: CGRect(x: 100, y: 0, width: 16, height: 24),
                               title: "Connected", windowID: 0, bundleID: "com.example.app")
        peek.model.tiles = MenuBarEarFeed.tiles([item], face: { _ in nil }, changed: [])
        peek.model.width = ScreenBarPeekLayout.width(tileWidths: peek.model.tiles.map(\.width), hasWords: false)
        peek.relayout()
        #expect(panel.frame.height == 2 * ScreenBarPeekLayout.padding + ScreenBarPeekLayout.tileHeight)
        if NotchSurfaceRenderProofTests.enabled {
            try ProofRender.write(ScreenBarPeekView(model: peek.model), size: panel.frame.size,
                                  name: "menu-peek-measured-icons", settle: 0)
        }
    }

    @Test("show with a missing anchor retires an existing pinned popup")
    func missingAnchorRetiresExistingPopup() {
        let peek = ScreenBarPeek()
        let keys = CardEscapeWatchTests.FakeKeys()
        peek.keySource = keys.source
        var available = true
        peek.anchor = {
            available ? ScreenBarPeekAnchor(
                ear: CGRect(x: 5100, y: 5950, width: 32, height: 32),
                band: CGRect(x: 5000, y: 5940, width: 200, height: 2),
                screen: CGRect(x: 4000, y: 4000, width: 2000, height: 2000)) : nil
        }
        let panel = peek.makePanel()
        defer { peek.hide(); panel.orderOut(nil) }
        peek.show(pinned: true)
        #expect(peek.isShown && peek.isPinned && peek.listensForEscape)
        available = false
        peek.show(pinned: true)
        #expect(!peek.isShown && !peek.isPinned && !peek.listensForEscape)
        #expect(panel.ignoresMouseEvents)
    }

    @Test("an anchor lost during show leaves no visible popup or keyboard monitor")
    func lostAnchorCannotPresentGhost() {
        let peek = ScreenBarPeek()
        let keys = CardEscapeWatchTests.FakeKeys()
        peek.keySource = keys.source
        let panel = peek.makePanel()
        panel.setFrame(CGRect(x: 5000, y: 5000, width: 120, height: 48), display: false)
        defer { peek.hide(); panel.orderOut(nil) }
        var reads = 0
        peek.anchor = {
            reads += 1
            guard reads == 1 else { return nil }
            return ScreenBarPeekAnchor(ear: CGRect(x: 5100, y: 5950, width: 32, height: 32),
                                       band: CGRect(x: 5000, y: 5940, width: 200, height: 2),
                                       screen: CGRect(x: 4000, y: 4000, width: 2000, height: 2000))
        }
        peek.show(pinned: true)
        #expect(!peek.isShown)
        #expect(!peek.isPinned)
        #expect(!peek.listensForEscape)
        #expect(!panel.isVisible, "relayout lost the anchor, so presentation must not continue")
    }
}
