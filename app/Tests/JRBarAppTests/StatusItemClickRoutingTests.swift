import AppKit
import Testing
@testable import JRBarApp

@Suite("Status item click coordinates")
@MainActor
struct StatusItemClickRoutingTests {
    init() { _ = NSApplication.shared }

    @Test("a centered native status event cannot turn an icon click into a spacer click")
    func centeredNativeEventUsesPointer() throws {
        let window = NSWindow(contentRect: NSRect(x: 800, y: 600, width: 220, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = NSButton(frame: NSRect(x: 8, y: 20, width: 187, height: 24))
        window.contentView?.addSubview(button)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp,
            location: NSPoint(x: 101.5, y: 32), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        #expect(event.window === window)
        let reported = button.convert(event.locationInWindow, from: nil)
        #expect(reported.x == 93.5)
        let blank = StatusItemController.boundaryRevealBounds(button.bounds, spacer: 144, glyphWidth: 43)
        #expect(blank.contains(reported))
        for x in [CGFloat(50), CGFloat(134), CGFloat(165.5)] {
            let expected = NSPoint(x: x, y: 12)
            let screen = window.convertPoint(toScreen: button.convert(expected, to: nil))
            let point = try #require(StatusItemController.clickPoint(button: button, screenPoint: screen))
            #expect(point == expected)
            #expect(blank.contains(point) == (x < 124))
        }
    }

    @Test("physical pointer positions keep narrow and wide icons outside the reveal seat",
          arguments: [CGFloat(24), CGFloat(108)])
    func externalEventKeepsIconClick(glyphWidth: CGFloat) throws {
        let window = NSWindow(contentRect: NSRect(x: 800, y: 600, width: 300, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = NSButton(frame: NSRect(x: 10, y: 20, width: 150 + glyphWidth, height: 24))
        window.contentView?.addSubview(button)
        let icon = NSPoint(x: 150 + glyphWidth / 2, y: 12)
        let screen = window.convertPoint(toScreen: button.convert(icon, to: nil))
        let point = try #require(StatusItemController.clickPoint(button: button, screenPoint: screen))
        #expect(point == icon)
        let blank = StatusItemController.boundaryRevealBounds(button.bounds, spacer: 150,
                                                              glyphWidth: glyphWidth)
        #expect(!blank.contains(point))
    }

    @Test("screen coordinates preserve the blank, chevron and icon seats on translated screens",
          arguments: [CGFloat(-1000), CGFloat(800)])
    func translatedClickSeats(originX: CGFloat) throws {
        let window = NSWindow(contentRect: NSRect(x: originX, y: 600, width: 300, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = NSButton(frame: NSRect(x: 10, y: 20, width: 174, height: 24))
        window.contentView?.addSubview(button)
        let blank = StatusItemController.boundaryRevealBounds(button.bounds, spacer: 150)
        for x in [CGFloat(50), CGFloat(140), CGFloat(162)] {
            let expected = NSPoint(x: x, y: 12)
            let screen = window.convertPoint(toScreen: button.convert(expected, to: nil))
            let point = try #require(StatusItemController.clickPoint(button: button, screenPoint: screen))
            #expect(point == expected)
            #expect(blank.contains(point) == (x < 130))
        }
    }
}
