import AppKit
import JRBarCore
import SwiftUI

/// The first-launch card: one small panel that says what the Screen Bar
/// is and the three things worth knowing, then gets out of the way. It is
/// not a wizard and not a tour — "Got it" is the whole thing.
///
/// Presented once, from `AppDelegate.completeFirstRun`, after the
/// hook-install toast on the launch that registers the login item. Two
/// facts keep it from ever repeating: that launch is the only one where
/// `loginItemRegistered` is still false, and `wasShown` — a marker file
/// next to `app-state.json` in the state directory — survives the state
/// file being reset. It is a file and not a user default for the same
/// reason `AppState` is: cfprefsd refused this app's domain on the
/// owner's Mac.
@MainActor
final class FirstRunCard: NSObject, NSWindowDelegate {
    /// `first-run-card.json` beside `app-state.json`; existence is the flag.
    static var markerURL: URL {
        AppStateFile.defaultURL().deletingLastPathComponent().appending(path: "first-run-card.json")
    }

    static var wasShown: Bool { FileManager.default.fileExists(atPath: markerURL.path) }

    private var panel: FirstRunCardPanel?
    /// Under the band, as with the HUD, so the card hangs off the thing it
    /// describes; nil falls back to the top centre of the notched screen.
    private let anchorRect: @MainActor () -> NSRect?
    /// The "Open Settings" button.
    var onOpenSettings: (() -> Void)?

    init(anchorRect: @escaping @MainActor () -> NSRect?) {
        self.anchorRect = anchorRect
        super.init()
    }

    func show() {
        guard !Self.wasShown, panel == nil else { return }
        Self.markShown()
        let panel = FirstRunCardPanel()
        panel.onDismiss = { [weak self] in self?.dismiss() }
        let view = FirstRunCardView(
            onGotIt: { [weak panel] in panel?.onDismiss?() },
            onOpenSettings: { [weak self, weak panel] in
                panel?.onDismiss?()
                self?.onOpenSettings?()
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        let plain = ProcessInfo.processInfo.environment["JRBAR_PLAIN_MATERIAL"] != nil
        if !plain {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: FirstRunCardView.width, height: 200))
            glass.cornerRadius = PanelController.cornerRadius
            glass.style = .regular
            glass.contentView = hosting
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: FirstRunCardView.width, height: 200))
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = PanelController.cornerRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            hosting.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            panel.contentView = effect
        }
        panel.delegate = self
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let band = anchorRect() ?? NotchHUD.fallbackAnchor()
        let screen = NSScreen.screens.first { $0.frame.intersects(band) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = band.midX - size.width / 2
        x = min(screen.maxX - size.width - 6, max(screen.minX + 6, x))
        let origin = NSPoint(x: x.rounded(), y: (band.minY - 14 - size.height).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        self.panel = panel
        // A once-ever card may take focus: buttons and Esc need a key
        // window, and an accessory app is never key on its own. The same
        // two calls the Settings and History windows use.
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        NSApp.activate()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduced { panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 6)) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.1 : 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().alphaValue = 1
            if !reduced { panel.animator().setFrameOrigin(origin) }
        }
    }

    private func dismiss() {
        panel?.close()
    }

    /// Written when the card is presented, not when it is dismissed: a
    /// crash mid-first-run must not bring the card back.
    private static func markShown() {
        do {
            try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"shown\": true}\n".utf8).write(to: markerURL, options: [.atomic])
        } catch {
            NSLog("JR-Bar first-run card: could not write %@: %@", markerURL.path, error.localizedDescription)
        }
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

/// The card's window: borderless glass like the status panel, but keyable
/// so Return dismisses and Esc (`cancelOperation`) closes it.
@MainActor
final class FirstRunCardPanel: NSPanel {
    var onDismiss: (@MainActor () -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: FirstRunCardView.width, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        level = .popUpMenu
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

/// The card's content in the panel's own language: 13 pt type, colour only
/// where it carries meaning (provider tiles, the waiting pulse, the done
/// check), one row per fact.
struct FirstRunCardView: View {
    let onGotIt: @MainActor () -> Void
    let onOpenSettings: @MainActor () -> Void

    static let width: CGFloat = 344

    private var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The thing itself, miniaturised: a thin strip in provider colours.
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(LinearGradient(colors: ["claude", "codex", "gemini"].map { ProviderStyle.style(for: $0).accent },
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 96, height: 5)
            VStack(alignment: .leading, spacing: 5) {
                Text("The Screen Bar")
                    .font(.system(size: 15, weight: .semibold))
                Text("The thin band at the top edge of the screen is your agents' status — the colour is who, the motion is what they're doing.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                fact {
                    HStack(spacing: 5) {
                        ProviderTile(style: ProviderStyle.style(for: "claude"), size: 18)
                        ProviderTile(style: ProviderStyle.style(for: "codex"), size: 18)
                        ProviderTile(style: ProviderStyle.style(for: "gemini"), size: 18)
                    }
                } text: {
                    Text("Colour names the provider — every agent keeps its own.")
                }
                fact {
                    ActivityMark(activity: .waiting, accent: .orange, reduced: reduced)
                } text: {
                    Text("A pulse or a strobe means it is waiting on you.")
                }
                fact {
                    HStack(spacing: 8) {
                        ActivityMark(activity: .working, accent: ProviderStyle.style(for: "codex").accent, reduced: reduced)
                        ActivityMark(activity: .done, accent: .green, reduced: reduced)
                    }
                } text: {
                    Text("Everything else is working or done.")
                }
            }
            HStack {
                Button("Open Settings") { onOpenSettings() }
                Spacer()
                Button("Got it") { onGotIt() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
        }
        .padding(16)
        .frame(width: Self.width)
    }

    /// One row: the marks in a fixed-width column, the sentence beside them.
    private func fact<Marks: View>(@ViewBuilder marks: () -> Marks, @ViewBuilder text: () -> Text) -> some View {
        HStack(alignment: .center, spacing: 12) {
            marks()
                .frame(width: 64, alignment: .leading)
            text()
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
