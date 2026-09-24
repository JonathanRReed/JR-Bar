import AppKit
import JRBarCore
import SwiftUI

// MARK: - The card's live sample

/// The Dock card's live sample: a patch of desk with a Dock along its
/// foot and Safari's preview open over its icon, drawn at the card's
/// spacing, its distance from the Dock and its name-label cover — so a
/// knob shows what it does without a trip to the Dock. The panel sits
/// where `DockPlacement` would put it. With the cover off, the Dock's
/// name bubble shows in the band kept for it; with it on the bubble sits
/// under the glass, or peeks out below it when the gap is wide — as it
/// does on the real Dock.
///
/// Everything here is drawn: built-in stills and the apps' own icons,
/// never a capture, so opening Settings never lights macOS's recording
/// dot. The sample takes no clicks.
struct DockPreviewSample: View {
    var spacing: Double
    var dockGap: Double
    var coversLabel: Bool
    /// The sample's size on the card as a share of the desk's real
    /// points — the proofs draw it at 1.
    var scale: CGFloat = 0.6
    /// A measure beside the air between icon and glass — the placement
    /// proof's, off on the card.
    var showsMeasure = false

    /// The desk's real size: room for the widest spacing's panel, the
    /// farthest gap and the name band over a Dock of 55 pt tiles.
    static let desk = CGSize(width: 600, height: 364)
    /// Jonathan's `tilesize`, and a tile's reach off the Dock's glass.
    static let tile: CGFloat = 55
    static let dockPad: CGFloat = 6
    /// The Dock's own bubble over a hovered icon: 6 pt up, 22 tall.
    static let bubbleLift: CGFloat = 6
    static let bubbleHeight: CGFloat = 22

    /// The air between the icon's top and the glass: the frame math's
    /// answer for a panel over a bottom-Dock tile.
    static func air(dockGap: Double, coversLabel: Bool) -> CGFloat {
        let placement = DockPlacement(gap: CGFloat(dockGap), coversLabel: coversLabel)
        let tile = CGRect(x: 0, y: 0, width: Self.tile, height: Self.tile)
        let screen = CGRect(x: -2000, y: -2000, width: 4000, height: 4000)
        let frame = placement.frame(anchor: tile, edge: .bottom, size: CGSize(width: 10, height: 10),
                                    screen: screen, title: "Safari")
        return frame.minY - tile.maxY
    }

    var body: some View {
        let air = Self.air(dockGap: dockGap, coversLabel: coversLabel)
        DockSampleDesk(content: DockPreviewSamples.browser(spacing: spacing),
                       air: air, showsMeasure: showsMeasure)
            .frame(width: Self.desk.width, height: Self.desk.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: Self.desk.width * scale, height: Self.desk.height * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sample preview at the spacing and distance set below")
    }
}

/// The sample's desk at real size: the wash, the Dock, the bubble and
/// the preview, stacked from the Dock up.
private struct DockSampleDesk: View {
    let content: DockPreviewContent
    let air: CGFloat
    let showsMeasure: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pad = DockPreviewSample.dockPad
        let tile = DockPreviewSample.tile
        ZStack(alignment: .bottom) {
            DockSampleWallpaper(dark: dark)
            dockGlass
                .padding(.bottom, pad)
            // The bubble is the Dock's, drawn in the Dock's window: a
            // covering preview hides whatever of it reaches under the
            // glass, so only the part below the glass shows.
            bubble
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: max(0, air - DockPreviewSample.bubbleLift))
                }
                .padding(.bottom, pad * 2 + tile + DockPreviewSample.bubbleLift)
            // The air runs from the icon's top, as the frame math reads
            // the tile — a tight gap lets the glass sit on the Dock's rim.
            VStack(spacing: 0) {
                DockPreviewView(content: content, actions: DockPreviewActions(content: content))
                    .fixedSize()
                    .background(DockSampleGlass(radius: content.metrics.panelRadius, dark: dark))
                Color.clear
                    .frame(width: 1, height: air)
                    .overlay(alignment: .leading) { if showsMeasure { measure } }
                icons
            }
            .padding(.bottom, pad * 2)
        }
    }

    private var dark: Bool { scheme == .dark }
    private var bubbleInk: Color { dark ? Color.white : Color.black.opacity(0.85) }
    private var bubbleFill: Color { dark ? Color(white: 0.22).opacity(0.92) : Color(white: 0.96).opacity(0.94) }
    private var dockFill: Color { dark ? Color.white.opacity(0.12) : Color.white.opacity(0.4) }
    private var dockRim: Color { Color.white.opacity(dark ? 0.16 : 0.6) }

    /// The Dock's own name bubble over the hovered icon.
    private var bubble: some View {
        Text(content.appName)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(bubbleInk)
            .padding(.horizontal, 10)
            .frame(height: DockPreviewSample.bubbleHeight)
            .background(Capsule().fill(bubbleFill))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }

    /// Five tiles with the previewed app in the middle, under the
    /// panel's centre.
    private var icons: some View {
        HStack(spacing: Self.tileGap) {
            ForEach(Array(DockPreviewSamples.dockIcons.enumerated()), id: \.offset) { _, icon in
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: DockPreviewSample.tile, height: DockPreviewSample.tile)
            }
        }
    }

    private static let tileGap: CGFloat = 4

    /// The Dock's own glass behind the tiles, reaching `dockPad` past them.
    private var dockGlass: some View {
        let count = CGFloat(DockPreviewSamples.dockIcons.count)
        let width = count * DockPreviewSample.tile + (count - 1) * Self.tileGap + DockPreviewSample.dockPad * 2
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return shape
            .fill(dockFill)
            .overlay(shape.strokeBorder(dockRim, lineWidth: 0.75))
            .frame(width: width, height: DockPreviewSample.tile + DockPreviewSample.dockPad * 2)
    }

    /// The placement proof's ruler: a bracket down the air and its size.
    private var measure: some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 1.5, height: air)
            Text("\(Int(air.rounded())) pt")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
                .fixedSize()
        }
        .offset(x: DockPreviewSample.tile / 2 + 8)
    }
}

/// The desk's wash: a desktop-like gradient for the glass to sit on.
private struct DockSampleWallpaper: View {
    let dark: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: dark
                           ? [Color(red: 0.10, green: 0.12, blue: 0.24), Color(red: 0.24, green: 0.12, blue: 0.30)]
                           : [Color(red: 0.62, green: 0.74, blue: 0.93), Color(red: 0.93, green: 0.76, blue: 0.80)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [dark ? Color(red: 0.20, green: 0.36, blue: 0.62)
                                         : Color(red: 0.98, green: 0.88, blue: 0.62), .clear],
                           center: UnitPoint(x: 0.25, y: 0.2), startRadius: 0, endRadius: 420)
        }
    }
}

/// A stand-in for the preview's Liquid Glass: a frosted fill, a rim and
/// a soft lift, at the spacing's corner.
private struct DockSampleGlass: View {
    let radius: CGFloat
    let dark: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(dark ? Color(white: 0.13).opacity(0.78) : Color(white: 0.98).opacity(0.72))
            .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.16 : 0.55), lineWidth: 0.75))
            .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 18, y: 8)
    }
}

// MARK: - Sample content

/// The preview's built-in sample content — a browser's pages, a
/// terminal running agents, a player, a folder — at real proportions,
/// with the apps' own icons. The Dock card's sample and the render
/// proofs draw from the same fixtures.
@MainActor
enum DockPreviewSamples {
    static func icon(_ path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    /// An app's icon by bundle id, or the generic app icon when it
    /// isn't installed.
    static func appIcon(_ bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSWorkspace.shared.icon(for: .application)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static var terminalIcon: NSImage {
        FileManager.default.fileExists(atPath: "/Applications/Ghostty.app")
            ? icon("/Applications/Ghostty.app") : icon("/System/Applications/Utilities/Terminal.app")
    }

    /// The sample Dock's five tiles, Safari in the middle.
    static let dockIcons: [NSImage] = [
        appIcon("com.apple.finder"), appIcon("com.apple.mail"), appIcon("com.apple.Safari"),
        terminalIcon, appIcon("com.apple.Music"),
    ]

    static func mark(_ id: String, provider: String, name: String, label: String,
                     activity: SessionActivity, fact: String? = nil, ask: CoreAsk? = nil) -> DockAgentMark {
        DockAgentMark(sessionID: id, provider: provider, providerName: name, label: label,
                      cwd: "/Users/jonathanreed/Downloads/JR-Bar", cwdTail: "Downloads/JR-Bar",
                      activity: activity, fact: fact, ask: ask,
                      hosts: ["com.mitchellh.ghostty"], tty: nil)
    }

    static let waitingAsk = CoreAsk(session: "claude:proof", openedAt: Date().timeIntervalSince1970 - 90,
                                    summary: "Bash: swift test --filter DockSwitcher",
                                    answerable: true, request: "request:v1:proof",
                                    preview: "swift test --filter DockSwitcher")

    static var waiting: DockAgentMark {
        mark("claude:proof", provider: "claude", name: "Claude", label: "polish the dock",
             activity: .waiting, ask: waitingAsk)
    }

    static var working: DockAgentMark {
        mark("codex:proof", provider: "codex", name: "Codex", label: "release notes",
             activity: .working, fact: "running Edit")
    }

    static func window(_ id: Int, _ title: String, still: NSImage? = nil,
                       minimized: Bool = false, fullScreen: Bool? = false) -> DockPreviewWindow {
        DockPreviewWindow(id: id, title: title, minimized: minimized, fullScreen: fullScreen,
                          frame: nil, thumbnail: still, element: nil)
    }

    /// Drawn once: a sample's stills are the same pixels every time.
    private static let browserStills = [DockSampleStill.browser(hue: 0.58), DockSampleStill.browser(hue: 0.02),
                                        DockSampleStill.browser(hue: 0.75)]
    private static let terminalStills = [DockSampleStill.terminal(.waiting), DockSampleStill.terminal(.working),
                                         DockSampleStill.terminal(.idle)]

    /// Safari with three pages, one minimized — the card's sample.
    static func browser(spacing: Double = 1) -> DockPreviewContent {
        let content = DockPreviewContent()
        content.metrics = DockPreviewMetrics.scaled(spacing)
        content.appName = "Safari"
        content.icon = appIcon("com.apple.Safari")
        content.bundleID = "com.apple.Safari"
        content.isRunning = true
        content.badge = "3"
        content.windows = [
            window(1, "Liquid Glass — Apple Developer", still: browserStills[0]),
            window(2, "Raycast Store", still: browserStills[1]),
            window(3, "Pull request #412 · jr-bar", still: browserStills[2], minimized: true),
        ]
        return content
    }

    /// Ghostty with an agent waiting on you, one working, and a shell.
    static func terminal(large: Bool = false, spacing: Double = 1) -> DockPreviewContent {
        let content = DockPreviewContent()
        content.metrics = DockPreviewMetrics.scaled(spacing)
        content.largeCards = large
        content.appName = "Ghostty"
        content.icon = terminalIcon
        content.bundleID = "com.mitchellh.ghostty"
        content.isRunning = true
        content.windows = [
            window(1, "✳ polish the dock", still: terminalStills[0]),
            window(2, "release notes — codex", still: terminalStills[1]),
            window(3, "~/Downloads/JR-Bar — zsh", still: terminalStills[2]),
        ]
        content.agents = [1: waiting, 2: working]
        content.appAgents = [waiting, working]
        content.selectedWindowID = 2
        return content
    }

    /// Two windows and no Screen Recording: icon cards.
    static func noStills(spacing: Double = 1) -> DockPreviewContent {
        let content = DockPreviewContent()
        content.metrics = DockPreviewMetrics.scaled(spacing)
        content.appName = "T3 Code (Nightly)"
        content.icon = icon("/Applications/T3 Code (Nightly).app")
        content.bundleID = "com.t3.code"
        content.isRunning = true
        content.windows = [
            window(1, "JR-Bar — DockEnhancePanel.swift"),
            window(2, "notes.md", minimized: true),
        ]
        return content
    }

    /// Ten terminals: past the limit, a title list.
    static func compact(spacing: Double = 1) -> DockPreviewContent {
        let content = DockPreviewContent()
        content.metrics = DockPreviewMetrics.scaled(spacing)
        content.appName = "Ghostty"
        content.icon = terminalIcon
        content.bundleID = "com.mitchellh.ghostty"
        content.isRunning = true
        content.compact = true
        let titles = ["✳ polish the dock", "release notes — codex", "~/Downloads/JR-Bar — zsh",
                      "htop", "ssh studio.local", "python3 -m http.server", "vim README.md",
                      "~/src/site — zsh", "tail -f daemon.log", "git log --oneline"]
        content.windows = titles.enumerated().map { index, title in
            window(index + 1, title, minimized: index == 6, fullScreen: index == 4 ? true : false)
        }
        content.agents = [1: waiting, 2: working]
        content.appAgents = [waiting, working]
        content.selectedWindowID = 3
        return content
    }

    /// Safari with a phone-tall window, a page and a ribbon-wide window:
    /// the letterbox case, and with `hug` the cards that take each
    /// window's shape.
    static func shapes(hug: Bool, spacing: Double = DockEnhanceSettings.defaultSpacing) -> DockPreviewContent {
        let content = DockPreviewContent()
        content.metrics = DockPreviewMetrics.scaled(spacing)
        content.hugWindows = hug
        content.appName = "Safari"
        content.icon = appIcon("com.apple.Safari")
        content.bundleID = "com.apple.Safari"
        content.isRunning = true
        content.windows = [
            window(1, "Mobile layout — jr-bar.dev", still: DockSampleStill.portrait(hue: 0.55)),
            window(2, "Liquid Glass — Apple Developer", still: browserStills[0]),
            window(3, "Build dashboard", still: DockSampleStill.browser(hue: 0.33, size: CGSize(width: 960, height: 280))),
        ]
        return content
    }

    /// Music with a track playing.
    static func music(spacing: Double = 1) -> DockPreviewContent {
        let content = DockPreviewContent()
        content.metrics = DockPreviewMetrics.scaled(spacing)
        content.appName = "Music"
        content.icon = icon("/System/Applications/Music.app")
        content.bundleID = "com.apple.Music"
        content.isRunning = true
        content.media = AlcoveMedia(title: "Nightcall", artist: "Kavinsky", album: "OutRun", playing: true,
                                    artworkData: DockSampleStill.artwork(), bundleIdentifier: "com.apple.Music",
                                    duration: 258, elapsed: 97,
                                    timestamp: Date().timeIntervalSinceReferenceDate)
        content.windows = [window(1, "Music", still: DockSampleStill.browser(hue: 0.95))]
        return content
    }
}

// MARK: - Drawn stills

/// Window stills drawn for the samples — a terminal running an agent, a
/// browser page — at a real window's proportions, so a card's
/// letterboxing and corners read as they would over a capture.
enum DockSampleStill {
    enum TerminalState { case waiting, working, idle }

    static func draw(_ size: CGSize, _ body: (CGRect) -> Void) -> NSImage {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return NSImage(size: size) }
        // The point size first: the context takes its scale from it.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage(size: size) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Flip so drawing reads top-down like a window.
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        body(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static func text(_ string: String, at point: CGPoint, size: CGFloat, color: NSColor,
                     weight: NSFont.Weight = .regular, mono: Bool = true) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                        : NSFont.systemFont(ofSize: size, weight: weight)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        // Text draws unflipped: undo the flip locally around the line.
        cg.translateBy(x: point.x, y: point.y + size)
        cg.scaleBy(x: 1, y: -1)
        attributed.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func titleBar(_ rect: CGRect, dark: Bool, title: String) {
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: 28)).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: 12 + CGFloat(index) * 20, y: 8, width: 12, height: 12)).fill()
        }
        text(title, at: CGPoint(x: rect.width / 2 - CGFloat(title.count) * 3.2, y: 7), size: 11,
             color: dark ? NSColor(white: 0.75, alpha: 1) : NSColor(white: 0.3, alpha: 1),
             weight: .semibold, mono: false)
    }

    static func terminal(_ state: TerminalState) -> NSImage {
        draw(CGSize(width: 480, height: 300)) { rect in
            NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()
            NSBezierPath(rect: rect).fill()
            titleBar(rect, dark: true, title: state == .idle ? "zsh" : "claude")
            let dim = NSColor(white: 0.55, alpha: 1)
            let body = NSColor(white: 0.88, alpha: 1)
            let orange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
            var y: CGFloat = 40
            func line(_ string: String, _ color: NSColor, weight: NSFont.Weight = .regular) {
                text(string, at: CGPoint(x: 14, y: y), size: 10.5, color: color, weight: weight)
                y += 16
            }
            switch state {
            case .waiting:
                line("✳ polish the dock", orange, weight: .bold)
                line("⏺ Read(DockEnhancePanel.swift)", body)
                line("  ⎿  Read 1604 lines", dim)
                line("⏺ Bash(swift test --filter DockSwitcher)", body)
                y += 6
                NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 0.9).setStroke()
                let box = NSBezierPath(roundedRect: CGRect(x: 12, y: y, width: rect.width - 24, height: 92),
                                       xRadius: 6, yRadius: 6)
                box.lineWidth = 1
                box.stroke()
                y += 10
                text("Do you want to proceed?", at: CGPoint(x: 24, y: y), size: 10.5, color: body, weight: .semibold)
                y += 20
                text("❯ 1. Yes", at: CGPoint(x: 24, y: y), size: 10.5, color: orange)
                y += 16
                text("  2. Yes, and don't ask again for swift test", at: CGPoint(x: 24, y: y), size: 10.5, color: body)
                y += 16
                text("  3. No, and tell Claude what to do differently", at: CGPoint(x: 24, y: y), size: 10.5, color: body)
            case .working:
                line("codex  ›  release notes", NSColor(red: 0.2, green: 0.56, blue: 1, alpha: 1), weight: .bold)
                line("• Edited CHANGELOG.md (+42 -3)", body)
                line("• Ran git log --oneline v0.7..HEAD", body)
                line("  └ 431 commits", dim)
                line("• Editing docs/release-0.8.md", body)
                line("  ◦ Working (1m 12s · esc to interrupt)", dim)
            case .idle:
                line("~/Downloads/JR-Bar main ✓", NSColor(red: 0.4, green: 0.8, blue: 0.5, alpha: 1))
                line("❯ git status", body)
                line("On branch main", dim)
                line("nothing to commit, working tree clean", dim)
                line("❯ make test", body)
                line("  ✔ 1,842 tests passed in 41.2s", NSColor(red: 0.4, green: 0.8, blue: 0.5, alpha: 1))
                line("❯ ▍", body)
            }
        }
    }

    static func browser(hue: CGFloat, size: CGSize = CGSize(width: 480, height: 312)) -> NSImage {
        draw(size) { rect in
            NSColor.white.setFill()
            NSBezierPath(rect: rect).fill()
            titleBar(rect, dark: false, title: "")
            NSColor(white: 0.88, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 140, y: 5, width: 200, height: 18), xRadius: 6, yRadius: 6).fill()
            NSColor(hue: hue, saturation: 0.55, brightness: 0.92, alpha: 1).setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 28, width: rect.width, height: 120)).fill()
            NSColor(hue: hue, saturation: 0.7, brightness: 0.55, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 32, y: 62, width: 200, height: 22), xRadius: 4, yRadius: 4).fill()
            NSColor(white: 1, alpha: 0.8).setFill()
            NSBezierPath(roundedRect: CGRect(x: 32, y: 96, width: 140, height: 10), xRadius: 3, yRadius: 3).fill()
            for row in 0..<6 {
                NSColor(white: 0.82, alpha: 1).setFill()
                let width = rect.width - 64 - CGFloat((row * 37) % 90)
                NSBezierPath(roundedRect: CGRect(x: 32, y: 170 + CGFloat(row) * 20, width: width, height: 8),
                             xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    /// A portrait window — a phone-sized simulator or a narrow chat — for
    /// cards that take each window's shape.
    static func portrait(hue: CGFloat) -> NSImage {
        draw(CGSize(width: 300, height: 520)) { rect in
            NSColor(hue: hue, saturation: 0.12, brightness: 0.98, alpha: 1).setFill()
            NSBezierPath(rect: rect).fill()
            titleBar(rect, dark: false, title: "")
            NSColor(hue: hue, saturation: 0.6, brightness: 0.85, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 20, y: 48, width: rect.width - 40, height: 160),
                         xRadius: 14, yRadius: 14).fill()
            for row in 0..<8 {
                NSColor(white: 0.84, alpha: 1).setFill()
                let width = rect.width - 40 - CGFloat((row * 29) % 70)
                NSBezierPath(roundedRect: CGRect(x: 20, y: 232 + CGFloat(row) * 30, width: width, height: 12),
                             xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    static func artwork() -> Data? {
        let image = draw(CGSize(width: 120, height: 120)) { rect in
            let gradient = NSGradient(colors: [NSColor(red: 0.95, green: 0.25, blue: 0.55, alpha: 1),
                                               NSColor(red: 0.25, green: 0.12, blue: 0.55, alpha: 1)])
            gradient?.draw(in: rect, angle: -60)
            NSColor(red: 1, green: 0.8, blue: 0.3, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 30, y: 44, width: 60, height: 60)).fill()
        }
        return image.tiffRepresentation
    }
}
