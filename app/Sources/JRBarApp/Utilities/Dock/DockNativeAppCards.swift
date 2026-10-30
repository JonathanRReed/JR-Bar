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

struct DockRemindersCard: View {
    @Environment(\.dockPreviewSize) private var previewSize
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
        DockWidget(title: "Reminders", symbol: "list.bullet", open: actions.onRemindersOpen) {
            VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
                content
                if let writeNotice { Text(writeNotice).jrbarType(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if previewSize == .large, canWrite {
                    Button("New Reminder") { adding.toggle() }.buttonStyle(DockCapsuleButtonStyle())
                    if adding {
                        HStack {
                            TextField("New reminder", text: $draft).onSubmit { add() }
                            Button("Add") { add() }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private var canWrite: Bool {
        switch state {
        case .items, .stale: true
        default: false
        }
    }

    private func add() {
        if actions.onReminderAdd?(draft) == true { draft = ""; adding = false }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading: Text("Loading reminders…").foregroundStyle(.secondary)
        case .noAccess, .denied:
            VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
                Text("Reminders access is off").foregroundStyle(.secondary)
                Button(state == .denied ? "Open Settings" : "Allow Access") { actions.onRemindersAuth?() }
                    .buttonStyle(DockCapsuleButtonStyle(prominent: true))
            }
        case .items(let entries): rows(entries, stale: false)
        case .stale(let entries): rows(entries, stale: true)
        }
    }

    private func rows(_ entries: [ShelfRemindersModel.Entry], stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
            if stale { Text("Stale").jrbarType(.caption).foregroundStyle(.secondary) }
            if previewSize == .small {
                let today = entries.filter { $0.due.map { calendar.isDate($0, inSameDayAs: now) } == true }
                HStack(alignment: .firstTextBaseline) {
                    Text("\(today.count)").jrbarType(.title).monospacedDigit()
                    Text("due today").foregroundStyle(.secondary)
                }
                if let entry = entries.first {
                    if let due = entry.due, due < calendar.startOfDay(for: now) {
                        Text("Overdue").jrbarType(.caption).foregroundStyle(JRBarTokens.Ink.failure)
                    }
                    Text(entry.title).jrbarType(.headline).lineLimit(3)
                } else { Text(stale ? "Reminders unavailable" : "All done for today").foregroundStyle(.secondary) }
            } else if entries.isEmpty {
                Text(stale ? "Reminders are unavailable" : "All done for today").foregroundStyle(.secondary)
            } else if previewSize == .medium {
                ForEach(Array(entries.prefix(3))) { entry in reminder(entry) }
            } else {
                DockContentList(maximumHeight: previewSize.widgetContentHeight - 80) {
                    VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                        ForEach(entries) { entry in reminder(entry) }
                    }
                }
            }
        }
    }

    private func reminder(_ entry: ShelfRemindersModel.Entry) -> some View {
        HStack(spacing: JRBarTokens.Space.sm) {
            Button { actions.onReminderComplete?(entry) } label: {
                Image(systemName: "circle").jrbarType(.body).frame(width: 24, height: 28)
            }
            .buttonStyle(.plain).accessibilityLabel("Complete \(entry.title)")
            Text(entry.title).fontWeight(.medium).lineLimit(previewSize == .medium ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let due = entry.due {
                let overdue = due < calendar.startOfDay(for: now)
                if let words = Self.dueWords(due, hasTime: entry.hasTime, overdue: overdue, calendar: calendar) {
                    Text(words).jrbarType(.caption).monospacedDigit()
                        .foregroundStyle(overdue ? JRBarTokens.Ink.failure : JRBarTokens.Ink.secondary)
                }
            }
        }
        .frame(minHeight: previewSize.rowHeight)
    }

    static func dueWords(_ due: Date, hasTime: Bool, overdue: Bool, calendar: Calendar) -> String? {
        if overdue { return due.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)) }
        guard hasTime else { return nil }
        return due.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
    }
}

struct DockShortcutsCard: View {
    @Environment(\.dockPreviewSize) private var previewSize
    let state: DockShortcutsPreview.State
    var runs: [String: DockShortcutsPreview.RunState] = [:]
    let actions: DockPreviewActions

    var body: some View {
        DockWidget(title: "Shortcuts", symbol: "square.stack.3d.up.fill", open: actions.onShortcutsOpen, fillsSize: fillsTile) {
            VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
                content
                if previewSize == .large {
                    Button("New Shortcut") { actions.onShortcutNew?() }.buttonStyle(DockCapsuleButtonStyle())
                }
            }
        }
    }

    private var fillsTile: Bool {
        guard previewSize == .small else { return false }
        switch state {
        case .shortcuts(let names), .stale(let names): return !names.isEmpty
        default: return false
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading: Text("Loading shortcuts…").foregroundStyle(.secondary)
        case .unavailable: Text("Couldn't load shortcuts. Open Shortcuts to try again.").foregroundStyle(.secondary)
        case .shortcuts(let names): rows(names, stale: false)
        case .stale(let names): rows(names, stale: true)
        }
    }

    @ViewBuilder private func rows(_ names: [String], stale: Bool) -> some View {
        if stale { Text("Stale").jrbarType(.caption).foregroundStyle(.secondary) }
        if names.isEmpty { Text("No shortcuts").foregroundStyle(.secondary) }
        else if previewSize == .small {
            shortcut(names[0], stale: stale, tile: true).frame(maxHeight: .infinity)
        } else if previewSize == .medium {
            let columns = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: JRBarTokens.Space.sm) {
                ForEach(Array(names.prefix(4)), id: \.self) { name in
                    shortcut(name, stale: stale, tile: true).frame(height: 60)
                }
            }
        } else {
            DockContentList(maximumHeight: previewSize.widgetContentHeight - 48) {
                VStack(spacing: JRBarTokens.Space.xs) {
                    ForEach(names, id: \.self) { name in shortcut(name, stale: stale, tile: false) }
                }
            }
        }
    }

    private func shortcut(_ name: String, stale: Bool, tile: Bool) -> some View {
        let run = runs[name] ?? .idle
        return VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
            Button { actions.onShortcutRun?(name) } label: {
                HStack(spacing: JRBarTokens.Space.sm) {
                    Text(name).jrbarType(previewSize == .small ? .title3 : .callout).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: run == .done ? "checkmark" : run == .running ? "hourglass" : "play.fill")
                }
                .padding(tile ? JRBarTokens.Space.sm : JRBarTokens.Space.xs)
                .frame(maxWidth: .infinity, maxHeight: tile ? .infinity : nil)
                .frame(minHeight: previewSize.rowHeight)
                .background(tile ? Color.accentColor.opacity(0.14) : DockChrome.plateHover,
                            in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
            }
            .buttonStyle(.plain).accessibilityLabel("Run \(name)")
            .disabled(stale || runs.values.contains(.running))
            if run == .failed || run == .timedOut {
                let detail = run == .timedOut ? "Didn't finish within 10 seconds. It may need input." : "Couldn't run this shortcut."
                let brief = run == .timedOut ? "Timed out" : "Couldn't run"
                Text(previewSize == .large ? detail : brief)
                    .jrbarType(.caption).foregroundStyle(.secondary).lineLimit(2).help(detail)
                if previewSize == .large {
                    Button("Open in Shortcuts") { actions.onShortcutOpen?(name) }.buttonStyle(DockCapsuleButtonStyle())
                }
            }
        }
    }
}
