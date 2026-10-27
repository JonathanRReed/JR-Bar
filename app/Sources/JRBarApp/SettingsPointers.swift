import JRBarUI
import SwiftUI

/// Where a control that used to be offered in several places lives now.
/// Each has one home, and every other place it was draws a single line
/// with a link to the home instead of a second copy of the control. The
/// copy of a second control can disagree with the first; a link cannot.
enum SettingsHome: String, CaseIterable, Sendable {
    /// The panel and shelf summon keys, and the Menu Bar utility's keys.
    case hotkeys
    /// Which providers get a meter in the menu bar icon.
    case meters
    /// The brightness cap over every light.
    case brightness

    /// The chapter the control lives in.
    var chapter: SettingsStore.Chapter {
        switch self {
        case .hotkeys: return .shortcuts
        case .meters: return .agents
        case .brightness: return .devices
        }
    }

    /// The page the control lives on.
    var page: SettingsStore.Page { chapter.page }

    /// The row the link lands on, by the title the search index lists.
    var title: String {
        switch self {
        case .hotkeys: return "Show the panel"
        case .meters: return "Menu bar"
        case .brightness: return "Maximum brightness"
        }
    }

    /// The line left where the control used to be.
    var line: String {
        switch self {
        case .hotkeys: return "Hotkeys are on Shortcuts."
        case .meters: return "Choose providers on Providers."
        case .brightness: return "Maximum brightness is on Devices."
        }
    }

    /// The link's own words.
    var linkTitle: String {
        switch self {
        case .hotkeys: return "Open Shortcuts"
        case .meters: return "Open Providers"
        case .brightness: return "Open Devices"
        }
    }

    /// The search entry the link reveals: the page, scrolled to the row.
    var entry: SettingsSearchEntry? {
        SettingsSearch.rows.first { $0.chapter == chapter && $0.title == title }
    }
}

extension SettingsStore {
    /// Opens a control's home page scrolled to its row, as a search hit
    /// does. `titled` names another row on the same page (the shelf's
    /// key, beside the panel's).
    func revealHome(_ home: SettingsHome, titled: String? = nil) {
        let title = titled ?? home.title
        if let entry = SettingsSearch.rows.first(where: { $0.chapter == home.chapter && $0.title == title }) {
            reveal(entry)
        } else {
            open(chapter: home.chapter)
        }
    }

    /// General's line about the summon keys: what each is now, and where
    /// to change it. A key another app holds says so first.
    var summonHotkeyLine: String {
        if panelHotkeyEnabled, panelHotkeyRegistrationFailed {
            return "\(panelHotkeyLabel) is taken — rebind the panel's key on Shortcuts."
        }
        if shelfHotkeyEnabled, shelfHotkeyRegistrationFailed {
            return "\(shelfHotkeyLabel) is taken — rebind the shelf's key on Shortcuts."
        }
        let panel = panelHotkeyEnabled ? panelHotkeyLabel : "off"
        let shelf = shelfHotkeyEnabled ? shelfHotkeyLabel : "off"
        return "Panel key \(panel), shelf key \(shelf) — change them on Shortcuts."
    }
}

/// The one line and its link. It reveals the home row the way a search
/// hit does, so the page opens already scrolled to it.
struct SettingsPointerRow: View {
    @Bindable var store: SettingsStore
    let home: SettingsHome
    /// What the line says; the default is the home's own.
    var line: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(line ?? home.line)
                .jrbarType(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(home.linkTitle) { follow() }
                .buttonStyle(.link)
                .help("Go to \(home.page.title) › \(home.title)")
        }
        .settingRowStyle()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(home.page.title) settings")
    }

    private func follow() { store.revealHome(home) }
}
