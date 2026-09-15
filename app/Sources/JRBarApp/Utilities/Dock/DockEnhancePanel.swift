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
    /// A window row's click — the controller raises it.
    var onPick: (@MainActor (DockPreviewWindow) -> Void)?
    /// The header's "Open" for an app that isn't running.
    var onOpenApp: (@MainActor () -> Void)?
}

/// The Enhance preview's window: a borderless, nonactivating panel
/// floating just above Apple's Dock (dock-window level + 1 so a
/// magnified icon can't cover it), all-spaces like the bar. The
/// controller positions it; the view reads `DockPreviewContent`, so
/// late thumbnails re-render without a re-present.
@MainActor
final class DockPreviewPanel: NSPanel {
    let actions = DockPreviewActions()

    private let hosting: NSHostingView<DockPreviewView>

    init(content: DockPreviewContent) {
        hosting = NSHostingView(rootView: DockPreviewView(content: content, actions: actions))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 96),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = hosting
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
        return CGSize(width: min(fit.width, 560), height: fit.height)
    }

    /// Show at `target`, animating a short springy drift up off the
    /// dock — a 220 ms ease with a hint of overshoot, under the 250 ms
    /// cap, so the panel visibly tracks which icon summoned it. A
    /// retarget while visible just slides to the new anchor; dismiss
    /// stays instant (a leave means leave), and Reduce Motion snaps.
    func present(frame target: CGRect, dockedAt edge: DockEdge) {
        if isVisible, alphaValue > 0.5 {
            setFrame(target, display: true)
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

/// The panel's body: app header, then the window rows — thumbnail
/// when Screen Recording granted one, the app icon otherwise.
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
                Spacer(minLength: 8)
                if !content.isRunning {
                    Button("Open") { actions.onOpenApp?() }
                        .controlSize(.small)
                }
            }
            if !content.windows.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(content.windows) { window in
                            Button { actions.onPick?(window) } label: {
                                windowCard(window)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var subtitle: String {
        if !content.isRunning { return "Not running" }
        switch content.windows.count {
        case 0: return "No open windows"
        case 1: return "1 window"
        default: return "\(content.windows.count) windows"
        }
    }

    private func windowCard(_ window: DockPreviewWindow) -> some View {
        VStack(spacing: 4) {
            Group {
                if let thumbnail = window.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.quaternary)
                        if let icon = content.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 28, height: 28)
                                .opacity(0.6)
                        }
                    }
                }
            }
            .frame(width: 128, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 3) {
                if window.minimized {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Text(window.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 128)
        }
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }
}
