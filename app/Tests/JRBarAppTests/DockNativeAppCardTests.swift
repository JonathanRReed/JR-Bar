import AppKit
import EventKit
import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
final class SyntheticDockShortcutsReader: DockShortcutsReading {
    var arguments: [[String]] = []
    var replies: [(@MainActor (DockShortcutsResult) -> Void)] = []
    var cancellations = 0
    func execute(_ arguments: [String], completion: @escaping @MainActor (DockShortcutsResult) -> Void) -> () -> Void {
        self.arguments.append(arguments)
        replies.append(completion)
        return { self.cancellations += 1 }
    }
}

@MainActor
@Suite("Dock native app cards", .serialized, .timeLimit(.minutes(2)))
struct DockNativeAppCardTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func reminders(_ store: SyntheticShelfEventStore) -> DockRemindersPreview {
        let model = DockRemindersPreview(reader: ShelfReminderReader(store: store), notifications: NotificationCenter())
        model.authorization = { .fullAccess }
        model.clock = { Self.now }
        model.calendar = Self.calendar
        model.scheduleDeadline = { _ in {} }
        return model
    }

    @Test("each card switch defaults on, survives old state, and round-trips independently")
    func settings() throws {
        for json in ["{}", #"{"remindersPreview":null,"shortcutsPreview":"yes","messagesPreview":0}"#] {
            let value = try JSONDecoder().decode(DockEnhanceSettings.self, from: Data(json.utf8))
            #expect(value.remindersPreview && value.shortcutsPreview && value.messagesPreview)
        }
        let preferences = DockEnhancePreferences()
        var value = DockEnhanceSettings()
        preferences.read = { value }
        preferences.write = { value = $0 }
        preferences.remindersPreview = false
        #expect(!value.remindersPreview && value.shortcutsPreview && value.messagesPreview)
        preferences.shortcutsPreview = false
        preferences.messagesPreview = false
        let decoded = try JSONDecoder().decode(DockEnhanceSettings.self, from: JSONEncoder().encode(value))
        #expect(!decoded.remindersPreview && !decoded.shortcutsPreview && !decoded.messagesPreview)
        #expect(decoded.calendarPreview && decoded.mediaPreview)
    }

    @Test("off creates no card reader and performs no preflight or cache work", arguments: ["com.apple.reminders", "com.apple.shortcuts", "com.apple.MobileSMS"])
    func off(_ bundle: String) {
        let native = DockNativePreviews()
        var creations = 0
        native.makeReminders = { creations += 1; Issue.record("created reminders while off"); return reminders(SyntheticShelfEventStore()) }
        native.makeShortcuts = { creations += 1; return DockShortcutsPreview(reader: SyntheticDockShortcutsReader()) }
        native.makeMessages = { creations += 1; return DockMessagesPreview(readBadge: { _ in Issue.record("read badge while off"); return .noBadge }) }
        let content = DockPreviewContent()
        content.bundleID = bundle
        content.isRunning = true
        let settings = DockEnhanceSettings(calendarPreview: false, mediaPreview: false,
                                           remindersPreview: false, shortcutsPreview: false, messagesPreview: false)
        native.seed(content: content, settings: settings)
        native.start(content: content, settings: settings)
        native.tileChanged(badge: "9", running: true)
        #expect(creations == 0)
        #expect(native.reminders == nil && native.shortcuts == nil && native.messages == nil)
        #expect(!content.hasNativeCard)
        native.stop()
    }

    @Test("Dock and shelf use one store and one in-flight fetch, including close and refresh")
    func sharedReminders() {
        let store = SyntheticShelfEventStore()
        let reader = ShelfReminderReader(store: store)
        let shelf = ShelfRemindersModel(reader: reader)
        shelf.authorization = { .fullAccess }
        shelf.scheduleRefreshOverride = {}
        let dock = DockRemindersPreview(reader: reader, notifications: NotificationCenter())
        dock.authorization = { .fullAccess }
        dock.clock = { Self.now }
        dock.calendar = Self.calendar
        dock.scheduleDeadline = { _ in {} }
        #expect(dock.reader === reader)
        #expect(dock.reader.store === store)
        #expect(ShelfReminderReader.shared.store === SystemShelfEventStore.shared)
        shelf.sync(enabled: true)
        dock.start()
        for _ in 0..<20 { dock.refresh() }
        #expect(store.fetches == 1 && store.peakInFlight == 1)
        store.answer(1, with: [])
        #expect(store.fetches == 2 && store.peakInFlight == 1)
        dock.stop()
        #expect(store.inFlight == 1)
        store.answer(2, with: [])
        #expect(dock.state == .loading)
        #expect(store.fetches == 2)
        shelf.stop()
    }

    @Test("Reminders permission matrix never fetches without full access",
          arguments: [EKAuthorizationStatus.notDetermined, .denied, .restricted, .writeOnly])
    func reminderPermissions(_ status: EKAuthorizationStatus) {
        let store = SyntheticShelfEventStore()
        let model = reminders(store)
        model.authorization = { status }
        model.start()
        #expect(store.fetches == 0)
        #expect(model.state == (status == .denied || status == .restricted ? .denied : .noAccess))
        #expect(store.calls.withLock { $0.permissions.isEmpty })
        model.stop()
    }

    @Test("Reminders loading, due filter, empty, stale, writes and store signals")
    func reminderStates() async {
        let store = SyntheticShelfEventStore()
        let model = reminders(store)
        model.start()
        #expect(model.state == .loading)
        let today = ShelfRemindersModel.Entry(id: "today", title: "Send the slides", due: Self.now)
        let old = ShelfRemindersModel.Entry(id: "old", title: "Renew library card", due: Self.now.addingTimeInterval(-86400))
        let later = ShelfRemindersModel.Entry(id: "later", title: "Later", due: Self.now.addingTimeInterval(86400))
        let undated = ShelfRemindersModel.Entry(id: "undated", title: "Undated", due: nil)
        store.answer(1, with: [later, today, undated, old])
        #expect(model.state == .items([old, today]))
        model.notifications.post(name: .EKEventStoreChanged, object: nil)
        await notificationTurn()
        #expect(store.fetches == 2)
        store.answer(2, with: nil)
        #expect(model.state == .stale([old, today]))
        model.complete(today)
        #expect(store.calls.withLock { $0.completed } == ["today"])
        store.answer(3, with: [])
        #expect(model.state == .items([]))
        model.complete(today)
        #expect(store.calls.withLock { $0.completed.count } == 1)
        model.add("Water the plants")
        #expect(store.calls.withLock { $0.drafts.first?.title } == "Water the plants")
        store.answer(4, with: [])
        model.stop()
        model.notifications.post(name: .EKEventStoreChanged, object: nil)
        model.refresh()
        #expect(store.fetches == 4)
    }

    private func notificationTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("a synchronous store signal waits for the write and coalesces its refresh")
    func notificationDuringWrite() async {
        let store = SyntheticShelfEventStore()
        defer { store.onComplete = nil }
        let model = reminders(store)
        let entry = ShelfRemindersModel.Entry(id: "one", title: "Synthetic reminder", due: Self.now)
        model.start()
        store.answer(1, with: [entry])
        let center = model.notifications
        store.onComplete = {
            center.post(name: .EKEventStoreChanged, object: nil)
            MainActor.assumeIsolated { #expect(store.fetches == 1) }
        }
        model.complete(entry)
        #expect(store.fetches == 2)
        await notificationTurn()
        #expect(store.fetches == 2)
        store.answer(2, with: [])
        model.stop()
    }

    @Test("a slow reminder fetch marks the last reading stale without cancelling or starting another fetch")
    func slowReminders() {
        let store = SyntheticShelfEventStore()
        let model = reminders(store)
        var deadline: (@MainActor () -> Void)?
        model.scheduleDeadline = { deadline = $0; return {} }
        model.start()
        deadline?()
        #expect(model.state == .stale([]))
        #expect(store.inFlight == 1 && store.fetches == 1)
        store.answer(1, with: [])
        #expect(model.state == .items([]))
        model.stop()
    }

    @Test("a failed reminder write keeps the row and explains the failure")
    func reminderWriteFailure() {
        let store = SyntheticShelfEventStore()
        let model = reminders(store)
        let entry = ShelfRemindersModel.Entry(id: "one", title: "Synthetic reminder", due: Self.now)
        model.start()
        store.answer(1, with: [entry])
        store.writeError = NSError(domain: "SyntheticStore", code: 1)
        model.complete(entry)
        #expect(model.state == .items([entry]))
        #expect(model.writeNotice != nil)
        #expect(store.calls.withLock { $0.completed.isEmpty })
        model.stop()
    }

    @Test("permission revoked in flight drops private rows and writes")
    func revoke() {
        let store = SyntheticShelfEventStore()
        let model = reminders(store)
        model.start()
        model.authorization = { .denied }
        store.answer(1, with: [.init(id: "one", title: "Synthetic reminder", due: Self.now)])
        #expect(model.state == .denied)
        model.add("Another reminder")
        #expect(store.calls.withLock { $0.drafts.isEmpty })
        model.stop()
    }

    @Test("Shortcuts list and row state matrix", arguments: [DockShortcutsResult.success("ignored"), .failed, .timedOut])
    func shortcutStates(_ outcome: DockShortcutsResult) {
        let reader = SyntheticDockShortcutsReader()
        let model = DockShortcutsPreview(reader: reader)
        model.start()
        #expect(model.state == .loading)
        #expect(reader.arguments == [["list"]])
        let name = "Resize \"images\"; $(echo nope)"
        reader.replies[0](.success(name + "\nMorning Brief\n" + name + "\n"))
        #expect(model.state == .shortcuts([name, "Morning Brief"]))
        model.start()
        #expect(reader.arguments.count == 1)
        model.run("Unknown")
        #expect(reader.arguments.count == 1)
        model.run(name)
        #expect(reader.arguments.last == ["run", name])
        #expect(model.runs[name] == .running)
        model.run(name)
        #expect(reader.arguments.count == 2)
        reader.replies[1](outcome)
        let expected: DockShortcutsPreview.RunState = outcome == .failed ? .failed : outcome == .timedOut ? .timedOut : .done
        #expect(model.runs[name] == expected)
        model.refresh()
        reader.replies[2](.failed)
        #expect(model.state == .stale([name, "Morning Brief"]))
        model.stop()
        #expect(model.runs.isEmpty && model.state == .loading)
        reader.replies[0](.success("late"))
        #expect(model.state == .loading)
    }

    @Test("the production runner uses argv and closed stdin with synthetic executables only")
    func processBoundary() async {
        let echo = DockShortcutsReader(executable: "/bin/echo")
        let literal = "a; $(printf unsafe) & quote\""
        let echoed = await withCheckedContinuation { continuation in
            _ = echo.execute(["list", literal]) { continuation.resume(returning: $0) }
        }
        #expect(echoed == .success("list " + literal + "\n"))
        let cat = DockShortcutsReader(executable: "/bin/cat")
        let closed = await withCheckedContinuation { continuation in
            _ = cat.execute([]) { continuation.resume(returning: $0) }
        }
        #expect(closed == .success(""))
        let yes = DockShortcutsReader(executable: "/usr/bin/yes", timeout: 0)
        let timedOut = await withCheckedContinuation { continuation in
            _ = yes.execute(["list"]) { continuation.resume(returning: $0) }
        }
        #expect(timedOut == .timedOut)
    }

    @Test("Shortcuts failures are not an empty list", arguments: [DockShortcutsResult.failed, .timedOut, .success("")])
    func shortcutEmpty(_ result: DockShortcutsResult) {
        let reader = SyntheticDockShortcutsReader()
        let model = DockShortcutsPreview(reader: reader)
        model.start()
        reader.replies[0](result)
        #expect(model.state == (result == .success("") ? .shortcuts([]) : .unavailable))
        model.stop()
    }

    @Test("disabling releases each reader, cancels Shortcuts, and clears all card values")
    func disable() {
        let native = DockNativePreviews()
        let store = SyntheticShelfEventStore()
        let reminder = reminders(store)
        let shortcutReader = SyntheticDockShortcutsReader()
        native.makeReminders = { reminder }
        native.makeShortcuts = { DockShortcutsPreview(reader: shortcutReader) }
        let content = DockPreviewContent()
        var settings = DockEnhanceSettings(calendarPreview: false, mediaPreview: false)
        content.bundleID = "com.apple.reminders"
        native.start(content: content, settings: settings)
        settings.remindersPreview = false
        native.update(settings: settings)
        #expect(native.reminders == nil && content.remindersState == nil && !reminder.running)
        store.answer(1, with: [])
        #expect(content.remindersState == nil)
        content.bundleID = "com.apple.shortcuts"
        native.start(content: content, settings: settings)
        settings.shortcutsPreview = false
        native.update(settings: settings)
        #expect(shortcutReader.cancellations == 1)
        #expect(native.shortcuts == nil && content.shortcutsState == nil)
        content.bundleID = "com.apple.MobileSMS"
        native.start(content: content, settings: settings)
        settings.messagesPreview = false
        native.update(settings: settings)
        #expect(native.messages == nil && content.messagesState == nil)
        native.stop()
    }

    @Test("native cards collapse the window list until the person expands it")
    func nativeWindows() {
        let content = DockPreviewContent()
        content.remindersState = .items([])
        #expect(content.hasNativeCard && !content.showsWindows)
        content.nativeWindowsExpanded = true
        #expect(content.showsWindows)
        content.nativeWindowsExpanded = false
        content.remindersState = nil
        content.shortcutsState = .shortcuts([])
        #expect(content.hasNativeCard && !content.showsWindows)
        content.shortcutsState = nil
        content.messagesState = .noBadge
        #expect(content.hasNativeCard && !content.showsWindows)
    }

    @Test("Messages uses only the injected Dock badge and preserves unknown and stale states")
    func messages() {
        var reads = 0
        let model = DockMessagesPreview(readBadge: { badge in reads += 1; return DockMessagesPreview.read(badge) })
        #expect(model.update(running: false, badge: "4") == .notRunning)
        #expect(reads == 0)
        #expect(model.update(running: true, badge: "3") == .unread("3"))
        #expect(model.update(running: true, badge: nil) == .noBadge)
        #expect(model.update(running: true, badge: "•") == .badgeOnly)
        #expect(model.update(running: true, badge: "0") == .unread("0"))
        let native = DockNativePreviews()
        native.makeMessages = { model }
        let content = DockPreviewContent()
        content.bundleID = "com.apple.MobileSMS"
        content.isRunning = true
        content.badge = "3"
        native.start(content: content, settings: .init(calendarPreview: false, mediaPreview: false))
        native.tileChanged(badge: "5", running: true)
        #expect(content.messagesState == .unread("5"))
        native.badgeUnavailable()
        #expect(content.messagesState == .stale("5"))
        native.tileChanged(badge: nil, running: true)
        #expect(content.messagesState == .noBadge)
        native.stop()
    }
}

@Suite("Dock Music header and width")
struct DockMusicHeaderTests {
    @Test @MainActor func theHeaderNamesWhatThePlayerIsDoing() {
        #expect(DockPreviewContent.musicSubtitle(.playing) == "Playing")
        #expect(DockPreviewContent.musicSubtitle(.paused) == "Paused")
        #expect(DockPreviewContent.musicSubtitle(.stopped) == "Nothing playing")
        #expect(DockPreviewContent.musicSubtitle(.notRunning) == "Not running")
    }

    @Test @MainActor func nativeCardsKeepTheirSizeBesideWindowStrips() {
        #expect(DockPreviewView.stripWidth(cards: 144, nativeCard: true) == DockPreviewSize.medium.contentWidth)
        #expect(DockPreviewView.stripWidth(cards: 600, nativeCard: true) == DockPreviewSize.medium.contentWidth)
        #expect(DockPreviewView.stripWidth(cards: 144, nativeCard: false) == 144)
    }
}
