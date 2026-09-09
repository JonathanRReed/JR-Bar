import AppKit

/// The menu-bar item: a template glyph of the bar under a notch, tinted by
/// the aggregate agent state, and a small menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let headerItem = NSMenuItem()
    private let detailItem = NSMenuItem()
    private let feedItem = NSMenuItem()
    private let showBarItem: NSMenuItem
    var onToggleScreenBar: (@MainActor (Bool) -> Void)?
    var isScreenBarShown = true { didSet { showBarItem.state = isScreenBarShown ? .on : .off } }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        showBarItem = NSMenuItem(title: "Show Screen Bar", action: #selector(toggleScreenBar(_:)), keyEquivalent: "")
        super.init()

        statusItem.button?.image = Self.glyph()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "JR-Bar"

        headerItem.isEnabled = false
        detailItem.isEnabled = false
        feedItem.isEnabled = false
        showBarItem.target = self
        showBarItem.state = .on

        menu.addItem(headerItem)
        menu.addItem(detailItem)
        menu.addItem(feedItem)
        menu.addItem(.separator())
        menu.addItem(showBarItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit JR-Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.autoenablesItems = false
        statusItem.menu = menu
        update(state: .idle, detail: "Starting")
        setFeed(description: "resolving")
    }

    func update(state: AgentAggregateState, detail: String) {
        headerItem.attributedTitle = NSAttributedString(string: "JR-Bar  ·  \(state.label)", attributes: [
            .font: NSFont.menuBarFont(ofSize: 0).withWeight(.semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        detailItem.attributedTitle = NSAttributedString(string: detail, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        statusItem.button?.contentTintColor = state.tint
        statusItem.button?.toolTip = "JR-Bar · \(state.label)"
    }

    func setFeed(description: String) {
        feedItem.attributedTitle = NSAttributedString(string: "Feed: \(description)", attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }

    @objc private func toggleScreenBar(_ sender: NSMenuItem) {
        isScreenBarShown.toggle()
        onToggleScreenBar?(isScreenBarShown)
    }

    /// A rounded bar tucked under a small notch cap, as a template image so
    /// the menu bar tints it (and `contentTintColor` recolours it).
    static func glyph() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.withAlphaComponent(0.38).setFill()
            let cap = NSBezierPath()
            cap.move(to: NSPoint(x: 4.5, y: 15.5))
            cap.line(to: NSPoint(x: 13.5, y: 15.5))
            cap.line(to: NSPoint(x: 13.5, y: 12.2))
            cap.curve(to: NSPoint(x: 11.7, y: 10.4), controlPoint1: NSPoint(x: 13.5, y: 11.2), controlPoint2: NSPoint(x: 12.7, y: 10.4))
            cap.line(to: NSPoint(x: 6.3, y: 10.4))
            cap.curve(to: NSPoint(x: 4.5, y: 12.2), controlPoint1: NSPoint(x: 5.3, y: 10.4), controlPoint2: NSPoint(x: 4.5, y: 11.2))
            cap.close()
            cap.fill()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2.5, y: 5.6, width: 13, height: 3.6), xRadius: 1.8, yRadius: 1.8).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
