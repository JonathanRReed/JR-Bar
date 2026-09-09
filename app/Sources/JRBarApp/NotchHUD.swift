import AppKit
import SwiftUI

/// A brief glass pill under the notch: "SidePulse connected". Click-through,
/// never key, gone after two seconds.
@MainActor
final class NotchHUD {
    static let life: TimeInterval = 2.0

    private let panel = NotchHUDPanel()
    private var hide: DispatchWorkItem?
    /// Where the band sits, so the pill hangs a little below it; nil
    /// falls back to the top centre of the notched screen.
    var anchorRect: @MainActor () -> NSRect?

    init(anchorRect: @escaping @MainActor () -> NSRect?) {
        self.anchorRect = anchorRect
    }

    func show(_ text: String, symbol: String = "cable.connector") {
        let band = anchorRect() ?? Self.fallbackAnchor()
        panel.present(text: text, symbol: symbol, under: band)
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.panel.dismiss() } }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.life, execute: work)
    }

    static func fallbackAnchor() -> NSRect {
        let screen = ScreenBarGeometry.preferredScreen() ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let depth = screen.map { ScreenBarGeometry.notchDepth(of: $0) } ?? 0
        return NSRect(x: frame.midX - 90, y: frame.maxY - depth - 8, width: 180, height: 6)
    }
}

@MainActor
final class NotchHUDPanel: NSPanel {
    private let hosting: NSHostingView<NotchHUDView>
    private let backdrop: NSView
    private let model = NotchHUDModel()

    init() {
        hosting = NSHostingView(rootView: NotchHUDView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        let plain = ProcessInfo.processInfo.environment["JRBAR_PLAIN_MATERIAL"] != nil
        if !plain {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
            glass.cornerRadius = 15
            glass.style = .regular
            glass.contentView = hosting
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 15
            effect.layer?.masksToBounds = true
            hosting.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            backdrop = effect
        }
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 30), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = backdrop
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func present(text: String, symbol: String, under band: NSRect) {
        model.text = text
        model.symbol = symbol
        hosting.rootView = NotchHUDView(model: model)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let height = max(30, size.height)
        let width = max(80, size.width)
        (backdrop as? NSGlassEffectView)?.cornerRadius = height / 2
        backdrop.layer?.cornerRadius = height / 2
        let origin = NSPoint(x: (band.midX - width / 2).rounded(), y: (band.minY - 10 - height).rounded())
        let wasVisible = isVisible && alphaValue > 0.01
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        orderFrontRegardless()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !wasVisible, !reduced { setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 6)) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.1 : 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            animator().alphaValue = 1
            if !wasVisible, !reduced { animator().setFrameOrigin(origin) }
        }
    }

    func dismiss() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduced ? 0.08 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.alphaValue < 0.01 else { return }
                self.orderOut(nil)
            }
        })
    }
}

@MainActor
@Observable
final class NotchHUDModel {
    var text = ""
    var symbol = "cable.connector"
}

struct NotchHUDView: View {
    @Bindable var model: NotchHUDModel

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: model.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(model.text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .fixedSize()
    }
}
