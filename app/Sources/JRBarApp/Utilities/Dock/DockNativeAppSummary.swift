import Foundation

extension DockPreviewContent {
    var nativeAppSubtitle: String? {
        if let state = remindersState {
            switch state {
            case .loading: return "Loading reminders…"
            case .noAccess, .denied: return "Reminders access is off"
            case .stale: return "Stale"
            case .items(let entries):
                if entries.isEmpty { return "Nothing due today" }
                let start = Calendar.current.startOfDay(for: remindersNow)
                let overdue = entries.filter { ($0.due ?? remindersNow) < start }.count
                let today = entries.count - overdue
                return "\(overdue) overdue · \(today) due today"
            }
        }
        if let state = shortcutsState {
            switch state {
            case .loading: return "Loading shortcuts…"
            case .unavailable: return "Shortcuts unavailable"
            case .stale: return "Stale"
            case .shortcuts(let names):
                return names.count == 1 ? "1 shortcut" : "\(names.count) shortcuts"
            }
        }
        if let state = messagesState {
            switch state {
            case .notRunning: return "Not running"
            case .noBadge: return "No unread badge"
            case .unread(let count): return "\(count) unread"
            case .badgeOnly: return "Unread count unavailable"
            case .stale: return "Stale"
            }
        }
        return nil
    }
}
