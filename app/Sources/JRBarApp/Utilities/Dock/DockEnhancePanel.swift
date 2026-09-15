import AppKit
import JRBarCore
import Observation
import QuartzCore
import SwiftUI

/// The click handlers a `DockPreviewView` calls — a shared box so the
/// panel can be built before the controller's closures land, without
/// rebuilding the hosting tree.
@MainActor
@Observable
final class DockPreviewActions {
    /// A window card's click — the controller raises it.
    var onPick: (@MainActor (DockPreviewWindow) -> Void)?
    /// The card's × — close that window.
    var onClose: (@MainActor (DockPreviewWindow) -> Void)?
    /// The card's – — minimize, or bring a minimized window back.
    var onMinimize: (@MainActor (DockPreviewWindow) -> Void)?
    /// The header's "Open" for an app that isn't running.
    var onOpenApp: (@MainActor () -> Void)?
    /// The header's "Quit".
    var onQuitApp: (@MainActor () -> Void)?
    /// The header's "Hide".
    var onHideApp: (@MainActor () -> Void)?
}

/// The Enhance preview's window: a borderless, nonactivating glass
/// panel (it floats, so the material rule allows glass) just above
/// Apple's Dock — dock-window level + 1 so a magnified icon can't
/// cover it — all-spaces like the Dock. The controller positions it;
/// the view reads `DockPreviewContent`, so late thumbnails re-render
/// without a re-present.
@MainActor
final class DockPreviewPanel: NSPanel {
    let actions = DockPreviewActions()
    static let cornerRadius: CGFloat = 16

    private let hosting: NSHostingView<DockPreviewView>

    init(content: DockPreviewContent) {
        hosting = NSHostingView(rootView: DockPreviewView(content: content, actions: actions))
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 240, height: 96))
        glass.cornerRadius = Self.cornerRadius
        glass.style = .regular
        glass.contentView = hosting
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 96),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = glass
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        title = "JR-Bar Dock Preview"
        // Just over the Dock's own level so a magnified icon can't
        // draw across the panel.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The size the content wants, clamped so a many-windowed app
    /// can't sprawl the panel across the screen.
    func fittingSize() -> CGSize {
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let limit = (NSScreen.main?.frame.width ?? 1200) - 40
        return CGSize(width: min(fit.width, min(720, limit)), height: fit.height)
    }

    /// Show at `target`, animating a short springy drift up off the
    /// dock — a 220 ms ease with a hint of overshoot, under the 250 ms
    /// cap, so the panel visibly tracks which icon summoned it. A
    /// retarget while visible just slides to the new anchor; dismiss
    /// stays instant (a leave means leave), and Reduce Motion snaps.
    func present(frame target: CGRect, dockedAt edge: DockEdge) {
        if isVisible, alphaValue > 0.5 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(target, display: true)
            }
            orderFrontRegardless()
            return
        }
        let drift: CGFloat = 10
        var start = target
        switch edge {
        case .bottom: start.origin.y -= drift
        case .left: start.origin.x -= drift
        case .right: start.origin.x += drift
        }
        setFrame(start, display: false)
        alphaValue = 0
        orderFrontRegardless()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.03 : 0.22
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.25, 1.3, 0.4, 1)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
    }

    /// Instant — a leave means leave.
    func dismiss() {
        alphaValue = 0
        orderOut(nil)
    }
}

/// The panel's body: app header with its verbs, then the window cards
/// — thumbnail when Screen Recording granted one, the app icon
/// otherwise — each with hover-revealed close and minimize buttons.
/// Clicks report through `actions`.
struct DockPreviewView: View {
    let content: DockPreviewContent
    let actions: DockPreviewActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let icon = content.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(content.appName)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if content.isRunning {
                    Button("Hide") { actions.onHideApp?() }
                        .controlSize(.small)
                        .help("Hide \(content.appName) (⌘H)")
                    Button("Quit") { actions.onQuitApp?() }
                        .controlSize(.small)
                        .help("Quit \(content.appName)")
                } else {
                    Button("Open") { actions.onOpenApp?() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
            if !content.windows.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(content.windows) { window in
                            DockPreviewCard(window: window, icon: content.icon,
                                            size: DockEnhanceMath.cardSize(large: content.largeCards),
                                            actions: actions)
                        }
                    }
                    .padding(2)
                }
            }
        }
        .padding(10)
    }

    private var subtitle: String {
        if !content.isRunning { return "Not running" }
        let minimized = content.windows.filter(\.minimized).count
        switch content.windows.count {
        case 0: return "No open windows"
        case 1: return minimized == 1 ? "1 window, minimized" : "1 window"
        default:
            return minimized > 0
                ? "\(content.windows.count) windows, \(minimized) minimized"
                : "\(content.windows.count) windows"
        }
    }
}

/// One window's card: the thumbnail (or the icon), the title, and the
/// verbs that appear on hover — × closes, – minimizes or restores.
/// The face is the raise target.
struct DockPreviewCard: View {
    let window: DockPreviewWindow
    let icon: NSImage?
    let size: CGSize
    let actions: DockPreviewActions
    @ViewState private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                Button { actions.onPick?(window) } label: {
                    face
                }
                .buttonStyle(.plain)
                if hovering {
                    HStack(spacing: 4) {
                        verb("xmark", help: "Close window") { actions.onClose?(window) }
                        verb(window.minimized ? "arrow.up.left.and.arrow.down.right" : "minus",
                             help: window.minimized ? "Bring back" : "Minimize") {
                            actions.onMinimize?(window)
                        }
                    }
                    .padding(5)
                    .transition(.opacity)
                }
            }
            HStack(spacing: 3) {
                if window.minimized {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Text(window.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: size.width)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quaternary.opacity(0.45))))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(window.title)
    }

    @ViewBuilder
    private var face: some View {
        Group {
            if let thumbnail = window.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .background(Color.black.opacity(0.25))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 32, height: 32)
                            .opacity(0.7)
                    }
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .opacity(window.minimized ? 0.6 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }

    private func verb(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
