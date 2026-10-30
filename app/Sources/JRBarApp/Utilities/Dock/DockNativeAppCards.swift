import JRBarUI
import SwiftUI

struct DockRemindersPreviewSetting: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("Reminders preview", isOn: $isOn) }
}

struct DockShortcutsPreviewSetting: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("Shortcuts preview", isOn: $isOn) }
}

struct DockMessagesPreviewSetting: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("Messages preview", isOn: $isOn) }
}

struct DockRemindersCard: View {
    let state: DockRemindersPreview.State
    let now: Date
    var calendar = Calendar.current
    var writeNotice: String?
    let actions: DockPreviewActions
    @ViewState private var adding: Bool
    @ViewState private var draft: String

    init(state: DockRemindersPreview.State, now: Date, calendar: Calendar = .current,
         writeNotice: String? = nil, actions: DockPreviewActions, adding: Bool = false, draft: String = "") {
        self.state = state
        self.now = now
        self.calendar = calendar
        self.writeNotice = writeNotice
        self.actions = actions
        _adding = ViewState(wrappedValue: adding)
        _draft = ViewState(wrappedValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            if let writeNotice { Text(writeNotice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                Button("Open Reminders") { actions.onRemindersOpen?() }
                if canWrite { Button("New Reminder") { adding.toggle() } }
            }
            .buttonStyle(DockCapsuleButtonStyle(prominent: false))
            if adding && canWrite {
                HStack {
                    TextField("New reminder", text: $draft).onSubmit { add() }
                    Button("Add") { add() }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .jrbarType(.callout)
        .frame(width: 320, alignment: .leading)
    }

    private var canWrite: Bool {
        switch state {
        case .items, .stale: return true
        default: return false
        }
    }

    private func add() {
        if actions.onReminderAdd?(draft) == true {
            draft = ""
            adding = false
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading: Text("Loading reminders…").foregroundStyle(.secondary)
        case .noAccess, .denied:
            HStack {
                Text("Reminders access is off").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(state == .denied ? "Open Settings" : "Allow Access") { actions.onRemindersAuth?() }
                    .buttonStyle(DockCapsuleButtonStyle(prominent: true))
            }
        case .items(let entries): rows(entries, stale: false)
        case .stale(let entries): rows(entries, stale: true)
        }
    }

    private func rows(_ entries: [ShelfRemindersModel.Entry], stale: Bool) -> some View {
        let start = calendar.startOfDay(for: now)
        let overdue = entries.filter { ($0.due ?? now) < start }
        let today = entries.filter { ($0.due ?? now) >= start }
        return VStack(alignment: .leading, spacing: 10) {
            if stale { Text("Stale · Couldn't refresh reminders").foregroundStyle(.secondary) }
            if entries.isEmpty {
                Text(stale ? "Reminders are unavailable" : "All done for today").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        group("Overdue", entries: overdue, overdue: true)
                        group("Today", entries: today, overdue: false)
                    }
                }
                .frame(height: min(CGFloat(entries.count) * 38 + CGFloat(overdue.isEmpty || today.isEmpty ? 22 : 44), 280))
            }
        }
    }

    @ViewBuilder private func group(_ title: String, entries: [ShelfRemindersModel.Entry], overdue: Bool) -> some View {
        if !entries.isEmpty {
            Text(title).jrbarType(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 9) {
                    if let tint = entry.calendarColor {
                        Capsule().fill(Color(red: tint.red, green: tint.green, blue: tint.blue)).frame(width: 3)
                    }
                    Button { actions.onReminderComplete?(entry) } label: {
                        Image(systemName: "circle").jrbarType(.body).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Complete \(entry.title)")
                    Text(entry.title).fontWeight(.medium).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let due = entry.due, let when = time(due, hasTime: entry.hasTime, overdue: overdue) {
                        Text(when)
                            .jrbarType(.caption).monospacedDigit()
                            .foregroundStyle(overdue ? JRBarTokens.Ink.failure : JRBarTokens.Ink.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The row's due words. An all-day reminder under the Today heading
    /// needs none: the heading already says when it is due.
    static func dueWords(_ due: Date, hasTime: Bool, overdue: Bool, calendar: Calendar) -> String? {
        if overdue { return due.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)) }
        guard hasTime else { return nil }
        return due.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
    }

    private func time(_ due: Date, hasTime: Bool, overdue: Bool) -> String? {
        Self.dueWords(due, hasTime: hasTime, overdue: overdue, calendar: calendar)
    }
}

struct DockShortcutsCard: View {
    let state: DockShortcutsPreview.State
    var runs: [String: DockShortcutsPreview.RunState] = [:]
    let actions: DockPreviewActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            HStack(spacing: 8) {
                Button("Open Shortcuts") { actions.onShortcutsOpen?() }
                Button("New Shortcut") { actions.onShortcutNew?() }
            }
            .buttonStyle(DockCapsuleButtonStyle(prominent: false))
        }
        .jrbarType(.callout)
        .frame(width: 320, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading: Text("Loading shortcuts…").foregroundStyle(.secondary)
        case .unavailable: Text("Couldn't load shortcuts. Open Shortcuts to try again.").foregroundStyle(.secondary)
        case .shortcuts(let names): rows(names, stale: false)
        case .stale(let names): rows(names, stale: true)
        }
    }

    private func rows(_ names: [String], stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if stale { Text("Stale · Couldn't refresh shortcuts").foregroundStyle(.secondary) }
            if names.isEmpty {
                Text("No shortcuts").foregroundStyle(.secondary)
            } else {
                Text("Your shortcuts").jrbarType(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(names, id: \.self) { name in shortcut(name, stale: stale) }
                    }
                }
                .frame(height: min(CGFloat(names.count) * 40, 280))
            }
        }
    }

    private func shortcut(_ name: String, stale: Bool) -> some View {
        let run = runs[name] ?? .idle
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.purple)
                Text(name).fontWeight(.medium).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                switch run {
                case .running: Text("Running…").foregroundStyle(.secondary)
                case .idle, .done, .failed, .timedOut:
                    Button { actions.onShortcutRun?(name) } label: {
                        Image(systemName: run == .done ? "checkmark" : "play.fill")
                            .foregroundStyle(run == .done ? JRBarTokens.Ink.done : JRBarTokens.Ink.label)
                            .frame(width: 22, height: 22)
                            .background(DockChrome.plateHover, in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Run \(name)")
                    .disabled(stale || runs.values.contains(.running))
                }
            }
            if run == .failed || run == .timedOut {
                Text(run == .timedOut ? "Didn't finish within 10 seconds. It may need input." : "Couldn't run this shortcut.")
                    .foregroundStyle(.secondary)
                Button("Open in Shortcuts") { actions.onShortcutOpen?(name) }
                    .buttonStyle(DockCapsuleButtonStyle(prominent: false))
            }
        }
    }
}

struct DockMessagesCard: View {
    let state: DockMessagesPreview.State
    let actions: DockPreviewActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).jrbarType(.title1).fontWeight(.semibold).monospacedDigit()
            Text("JR-Bar reads only the Dock tile's badge. Message text and names stay in Messages.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Messages") { actions.onMessagesOpen?() }
                Button("New Message") { actions.onMessageNew?() }
            }
            .buttonStyle(DockCapsuleButtonStyle(prominent: false))
        }
        .jrbarType(.callout)
        .frame(width: 320, alignment: .leading)
    }

    private var title: String {
        switch state {
        case .notRunning: return "Messages is not open"
        case .noBadge: return "No unread badge"
        case .unread(let count): return "\(count) unread in Messages"
        case .badgeOnly: return "Messages has a badge"
        case .stale(let count): return count.map { "\($0) unread · Stale" } ?? "Dock badge unavailable · Stale"
        }
    }
}
