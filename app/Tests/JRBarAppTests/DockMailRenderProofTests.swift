import AppKit
import JRBarTestSupport
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Dock Mail render proofs", .serialized, .renderProofAppearance)
struct DockMailRenderProofTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func reading(stale: Bool = false) -> DockMailReading {
        let rows: [(String, String, TimeInterval, Bool)] = [
            ("Riverside Library", "Your hold is ready for pickup", 120, false),
            ("Morgan Lee", "Draft agenda for Thursday's review", 1080, true),
            ("Harbor Credit Union", "Your October statement is available", 3600, false),
            ("Priya Nair", "Invoice 2041 attached", 10800, true),
            ("Westfield Cycling Club", "Saturday ride: route and start time", 86400, false),
        ]
        let messages = rows.enumerated().map { index, row in
            DockMailMessage(id: "synthetic-\(index)@example.invalid", sender: row.0, subject: row.1,
                            received: now.addingTimeInterval(-row.2), flagged: row.3)
        }
        return DockMailReading(unread: 9, messages: stale ? Array(messages.prefix(3)) : messages,
                               date: now.addingTimeInterval(stale ? -360 : 0))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func cardsAndSettings() throws {
        let good = Self.reading()
        let cases: [(String, DockMailPreview.State)] = [
            ("messages", .messages(good)), ("no-access", .noAccess), ("denied", .denied),
            ("empty", .messages(DockMailReading(unread: 0, messages: [], date: Self.now))),
            ("not-running", .notRunning), ("stale", .stale(Self.reading(stale: true))),
            ("loading", .loading), ("timeout", .timeout),
            ("stale-empty", .stale(DockMailReading(unread: 0, messages: [], date: Self.now.addingTimeInterval(-360)))),
        ]
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for (name, state) in cases {
                let content = DockPreviewContent()
                content.appName = "Mail"
                content.bundleID = "com.apple.mail"
                content.icon = Self.icon()
                content.isRunning = state != .notRunning
                content.mailState = state
                content.mailNow = Self.now
                content.badge = state.reading.flatMap { $0.unread > 0 ? String($0.unread) : nil }
                let view = DockPreviewView(content: content, actions: DockPreviewActions(content: content))
                    .background(Color(nsColor: .windowBackgroundColor))
                try ProofRender.write(view, size: CGSize(width: 340, height: 1),
                    name: "dock-mail-\(name)-\(theme)", dark: dark, settle: 0)
            }
            let actions = DockPreviewActions(content: DockPreviewContent())
            let rowActions = DockMailCard(state: .messages(good), now: Self.now, actions: actions,
                                         highlightedMessageID: good.messages[1].id)
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor))
            try ProofRender.write(rowActions, size: CGSize(width: 340, height: 1),
                name: "dock-mail-row-actions-\(theme)", dark: dark, settle: 0)
            for enabled in [false, true] {
                let view = VStack(alignment: .leading, spacing: 16) {
                    Toggle("Calendar preview", isOn: .constant(true))
                    Toggle("Media preview", isOn: .constant(true))
                    DockMailPreviewSetting(isOn: .constant(enabled))
                }
                .toggleStyle(.switch)
                .environment(\.controlActiveState, .active)
                .tint(Color.accentColor)
                .padding(20)
                .frame(width: 440)
                .background(Color(nsColor: .windowBackgroundColor))
                try ProofRender.write(view, size: CGSize(width: 440, height: 1),
                    name: "dock-mail-settings-\(enabled ? "on" : "off")-\(theme)", dark: dark, settle: 0)
            }
        }
    }

    private static func icon() -> NSImage {
        let image = NSImage(size: CGSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 64, height: 64), xRadius: 14, yRadius: 14).fill()
        let glyph = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: "Mail")?
            .withSymbolConfiguration(.init(paletteColors: [.white]))
        glyph?.draw(in: CGRect(x: 10, y: 14, width: 44, height: 36))
        image.unlockFocus()
        return image
    }

    @Test("Mail remains excluded when the development capture override is used")
    func capturePrivacy() {
        let prior = ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"]
        setenv("JRBAR_CAPTURE_CARD", "1", 1)
        defer {
            if let prior { setenv("JRBAR_CAPTURE_CARD", prior, 1) }
            else { unsetenv("JRBAR_CAPTURE_CARD") }
        }
        let content = DockPreviewContent()
        let panel = DockPreviewPanel(content: content)
        panel.protectMail(false)
        #expect(panel.sharingType == .readOnly)
        panel.protectMail(true)
        #expect(panel.sharingType == .none)
        panel.close()
    }
}
