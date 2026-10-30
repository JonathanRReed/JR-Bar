import AppKit
import JRBarTestSupport
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Dock native app card render proofs", .serialized, .renderProofAppearance)
struct DockNativeAppCardRenderProofTests {
    static let now = DockNativeAppCardTests.now
    static let reminderModes = ["loading", "no-access", "denied", "empty", "due", "stale", "stale-empty", "write-failed", "long-title"]
    static let shortcutModes = ["loading", "unavailable", "empty", "list", "running", "done", "failed", "timed-out", "stale", "long-name"]
    static let messageModes = ["not-running", "no-badge", "unread", "badge-only", "stale", "stale-empty"]

    static func entries(long: Bool = false) -> [ShelfRemindersModel.Entry] {
        let title = long ? String(repeating: "Review the presentation and prepare the illustrations ", count: 3) : "Send the slides"
        let blue = ShelfCalendarModel.CalendarColor(red: 0, green: 0.48, blue: 1)
        return [
            .init(id: "old", title: "Renew library card", due: now.addingTimeInterval(-86400), calendarColor: .init(red: 1, green: 0.58, blue: 0)),
            .init(id: "today", title: title, due: now, calendarColor: blue),
            .init(id: "plants", title: "Water the plants", due: now, calendarColor: .init(red: 0.2, green: 0.78, blue: 0.35), hasTime: false),
        ]
    }

    static func reminderState(_ mode: String) -> DockRemindersPreview.State {
        switch mode {
        case "loading": return .loading
        case "no-access": return .noAccess
        case "denied": return .denied
        case "empty": return .items([])
        case "stale": return .stale(entries())
        case "stale-empty": return .stale([])
        default: return .items(entries(long: mode == "long-title"))
        }
    }

    static func shortcutState(_ mode: String) -> DockShortcutsPreview.State {
        let names = ["Morning Brief", "Resize Images", "Start Focus Session", "Clean Downloads", "Toggle Dark Mode", "Send Weekly Report"]
        switch mode {
        case "loading": return .loading
        case "unavailable": return .unavailable
        case "empty": return .shortcuts([])
        case "stale": return .stale(names)
        case "long-name": return .shortcuts([String(repeating: "Prepare the workshop illustrations ", count: 4)])
        default: return .shortcuts(names)
        }
    }

    static func messageState(_ mode: String) -> DockMessagesPreview.State {
        switch mode {
        case "not-running": return .notRunning
        case "no-badge": return .noBadge
        case "badge-only": return .badgeOnly
        case "stale": return .stale("3")
        case "stale-empty": return .stale(nil)
        default: return .unread("3")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func cards() throws {
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for mode in Self.reminderModes {
                let content = base("Reminders", bundle: "com.apple.reminders", symbol: "list.bullet")
                content.remindersState = Self.reminderState(mode)
                content.remindersNow = Self.now
                if mode == "write-failed" { content.remindersWriteNotice = "Couldn't mark that reminder done. Open Reminders to try again." }
                try write(content, name: "reminders-\(mode)-\(theme)", dark: dark)
            }
            let adding = DockRemindersCard(state: .items(Self.entries()), now: Self.now,
                actions: DockPreviewActions(content: DockPreviewContent()), adding: true, draft: "Water the plants")
                .padding(16).background(dark ? Color(nsColor: .windowBackgroundColor) : .white)
            try ProofRender.write(adding, size: CGSize(width: 360, height: 300),
                                  name: "u2-reminders-new-\(theme)", dark: dark, settle: 0)
            for mode in Self.shortcutModes {
                let content = base("Shortcuts", bundle: "com.apple.shortcuts", symbol: "square.stack.3d.up.fill")
                content.shortcutsState = Self.shortcutState(mode)
                switch mode {
                case "running": content.shortcutRuns["Resize Images"] = .running
                case "done": content.shortcutRuns["Resize Images"] = .done
                case "failed": content.shortcutRuns["Resize Images"] = .failed
                case "timed-out": content.shortcutRuns["Resize Images"] = .timedOut
                default: break
                }
                try write(content, name: "shortcuts-\(mode)-\(theme)", dark: dark)
            }
            for mode in Self.messageModes {
                let content = base("Messages", bundle: "com.apple.MobileSMS", symbol: "message.fill")
                content.messagesState = Self.messageState(mode)
                if mode == "unread" { content.badge = "3" }
                content.isRunning = mode != "not-running"
                try write(content, name: "messages-\(mode)-\(theme)", dark: dark)
            }
            for enabled in [false, true] {
                let settings = VStack(alignment: .leading, spacing: 0) {
                    DockRemindersPreviewSetting(isOn: .constant(enabled))
                    DockShortcutsPreviewSetting(isOn: .constant(enabled))
                    DockMessagesPreviewSetting(isOn: .constant(enabled))
                }
                .toggleStyle(CardToggleStyle()).controlSize(.small).padding(16)
                .background(dark ? Color(nsColor: .windowBackgroundColor) : .white)
                try ProofRender.write(settings, size: CGSize(width: 360, height: 142),
                                      name: "u2-settings-\(enabled)-\(theme)", dark: dark, settle: 0)
            }
        }
    }

    private func base(_ name: String, bundle: String, symbol: String) -> DockPreviewContent {
        let content = DockPreviewContent()
        content.appName = name
        content.bundleID = bundle
        content.isRunning = true
        content.icon = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        return content
    }

    private func write(_ content: DockPreviewContent, name: String, dark: Bool) throws {
        let scene = DockPreviewView(content: content, actions: DockPreviewActions(content: content))
            .padding(8)
            .background(dark ? Color(nsColor: .windowBackgroundColor) : .white)
        let host = NSHostingView(rootView: scene)
        host.layoutSubtreeIfNeeded()
        let height = max(120, host.fittingSize.height)
        try ProofRender.write(scene, size: CGSize(width: 360, height: height),
                              name: "u2-\(name)", dark: dark, settle: 0)
    }
}
