import AppKit
import JRBarCore
import SwiftUI
@testable import JRBarApp

// The Dock preview's test-only sample content: what the render proofs and
// the switcher tests draw beyond the Safari sample the Settings card
// shows (`DockPreviewSamples.browser`, in the app). Synthetic throughout.

// MARK: - Sample content

extension DockPreviewSamples {
    static func mark(_ id: String, provider: String, name: String, label: String,
                     activity: SessionActivity, fact: String? = nil, ask: CoreAsk? = nil) -> DockAgentMark {
        DockAgentMark(sessionID: id, provider: provider, providerName: name, label: label,
                      cwd: "/Users/me/Downloads/JR-Bar", cwdTail: "Downloads/JR-Bar",
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

    /// Drawn once: a sample's stills are the same pixels every time.
    private static let terminalStills = [DockSampleStill.terminal(.waiting), DockSampleStill.terminal(.working),
                                         DockSampleStill.terminal(.idle)]

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
        content.icon = safariIcon
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

extension DockSampleStill {
    enum TerminalState { case waiting, working, idle }

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
