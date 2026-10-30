import Foundation
import JRBarCore
import EventKit

/// Readers belong to the visible preview, independently of the notch's subscriptions.
@MainActor
final class DockNativePreviews {
    let feed: MediaFeed
    let calendar: DockCalendarPreview
    var onChange: () -> Void = {}
    private(set) var reminders: DockRemindersPreview?
    private(set) var shortcuts: DockShortcutsPreview?
    private(set) var messages: DockMessagesPreview?
    var makeReminders: () -> DockRemindersPreview = { DockRemindersPreview() }
    var makeShortcuts: () -> DockShortcutsPreview = { DockShortcutsPreview() }
    var makeMessages: () -> DockMessagesPreview = { DockMessagesPreview() }
    private(set) var mail: DockMailPreview?
    private(set) var mailCache: DockMailReading?
    private var mailCacheIsStale = false
    private var mailBadge: String?
    var makeMail: () -> DockMailPreview = { DockMailPreview() }
    var makeMusic: (MediaFeed) -> DockMusicPreview = { DockMusicPreview(source: .live(), feed: $0) }
    private var mediaToken: UUID?
    private weak var content: DockPreviewContent?

    init(feed: MediaFeed? = nil, calendar: DockCalendarPreview? = nil) {
        self.feed = feed ?? .shared
        self.calendar = calendar ?? DockCalendarPreview()
    }

    /// Seed the first frame from held values without starting either reader.
    func seed(content: DockPreviewContent, settings: DockEnhanceSettings) {
        discardMailIfDisabled(settings)
        content.mailState = settings.mailPreview && content.bundleID == DockEnhanceMath.mailBundleID
            ? (content.isRunning ? .loading : .notRunning) : nil
        let bundleID = content.bundleID
        content.musicPlayerEnabled = settings.musicPlayer && bundleID == DockMusicSource.bundleID
        content.media = settings.mediaPreview && bundleID != DockMusicSource.bundleID ? feed.media.flatMap {
            DockEnhanceMath.showsMediaRow(mediaBundleID: $0.bundleIdentifier, appBundleID: bundleID) ? $0 : nil
        } : nil
        content.mediaPending = settings.mediaPreview && bundleID != DockMusicSource.bundleID && content.isRunning && !feed.hasSnapshot
        content.remindersState = settings.remindersPreview && bundleID == "com.apple.reminders" ? .loading : nil
        content.shortcutsState = settings.shortcutsPreview && bundleID == "com.apple.shortcuts" ? .loading : nil
        content.messagesState = settings.messagesPreview && bundleID == "com.apple.MobileSMS"
            ? (content.isRunning ? DockMessagesPreview.read(content.badge) : .notRunning) : nil
        content.calendarNow = calendar.clock()
        content.calendarView = settings.calendarView
        content.calendarListDay = nil
        content.calendarMonth = calendar.calendar.dateInterval(of: .month, for: content.calendarNow)?.start
            ?? content.calendarNow
        content.calendarSelectedDay = calendar.calendar.startOfDay(for: content.calendarNow)
        content.calendarState = settings.calendarPreview && bundleID == DockEnhanceMath.calendarBundleID
            ? (calendar.authorization() == .fullAccess ? .loading : .noAccess) : nil
    }

    func start(content: DockPreviewContent, settings: DockEnhanceSettings) {
        stop()
        self.content = content
        update(settings: settings)
    }

    func update(settings: DockEnhanceSettings) {
        discardMailIfDisabled(settings)
        guard let content, let bundleID = content.bundleID else { return }
        content.mediaPending = settings.mediaPreview && bundleID != DockMusicSource.bundleID && content.isRunning && !feed.hasSnapshot
        let wantsMusic = settings.musicPlayer && bundleID == DockMusicSource.bundleID
        content.musicPlayerEnabled = wantsMusic
        if wantsMusic {
            if content.music == nil {
                let player = makeMusic(feed)
                player.onChange = { [weak self] in self?.onChange() }
                content.music = player
                player.start(fullControls: settings.musicFullControls)
            } else {
                content.music?.configure(fullControls: settings.musicFullControls)
            }
        } else {
            content.music?.stop()
            content.music = nil
        }
        let wantsMedia = settings.mediaPreview && bundleID != DockMusicSource.bundleID
        if wantsMedia, mediaToken == nil {
            mediaToken = feed.subscribe { [weak self, weak content] media in
                guard let self, let content else { return }
                content.mediaPending = content.isRunning && !self.feed.hasSnapshot
                content.media = media.flatMap {
                    DockEnhanceMath.showsMediaRow(mediaBundleID: $0.bundleIdentifier,
                                                 appBundleID: bundleID) ? $0 : nil
                }
                self.onChange()
            }
        } else if !wantsMedia {
            if let mediaToken { feed.unsubscribe(mediaToken) }
            mediaToken = nil
            content.media = nil
        }
        let wantsCalendar = settings.calendarPreview &&
            (bundleID == DockEnhanceMath.calendarBundleID || DockEnhanceMath.isMeetingApp(bundleID))
        if wantsCalendar {
            content.calendarView = settings.calendarView
            let month = bundleID == DockEnhanceMath.calendarBundleID && (settings.calendarView == .month || content.calendarListDay != nil)
                ? content.calendarMonth : nil
            calendar.show(month: month)
        }
        if wantsCalendar, !calendar.running {
            calendar.onChange = { [weak self, weak content] state in
                guard let self, let content else { return }
                content.calendarNow = self.calendar.clock()
                if bundleID == DockEnhanceMath.calendarBundleID {
                    content.calendarState = state
                } else if case .events(let events) = state {
                    let timed = events.filter { !$0.isAllDay }
                    let meeting = DockEnhanceMath.meetingEvent(for: bundleID, in: timed, now: content.calendarNow)
                    content.calendarState = meeting.map { .events([$0]) }
                } else {
                    content.calendarState = nil
                }
                self.onChange()
            }
            calendar.start()
        } else if !wantsCalendar {
            calendar.stop()
            content.calendarState = nil
        }
        let wantsMail = settings.mailPreview && bundleID == DockEnhanceMath.mailBundleID
        if wantsMail {
            if mail == nil {
                mail = makeMail()
                mail?.restore(mailCache, badge: mailBadge, stale: mailCacheIsStale)
            }
            mail?.onChange = { [weak self, weak content] state in
                guard let self, let content else { return }
                self.mailCache = self.mail?.cached
                self.mailCacheIsStale = self.mail?.cacheIsStale ?? false
                content.mailNow = self.mail?.clock() ?? Date()
                content.mailState = state
                self.onChange()
            }
            if mail?.visible == false { mail?.show(badge: content.badge) }
        } else {
            mail?.hide()
            content.mailState = nil
        }
        updateReminders(content: content, settings: settings)
        updateShortcuts(content: content, settings: settings)
        updateMessages(content: content, settings: settings)
        onChange()
    }

    private func updateReminders(content: DockPreviewContent, settings: DockEnhanceSettings) {
        guard settings.remindersPreview, content.bundleID == "com.apple.reminders" else {
            reminders?.stop()
            reminders = nil
            content.remindersState = nil
            content.remindersWriteNotice = nil
            return
        }
        guard reminders == nil else { return }
        let preview = makeReminders()
        reminders = preview
        preview.onChange = { [weak self, weak content, weak preview] state in
            guard let self, let content, let preview else { return }
            content.remindersState = state
            content.remindersWriteNotice = preview.writeNotice
            content.remindersNow = preview.clock()
            self.onChange()
        }
        preview.start()
    }

    private func updateShortcuts(content: DockPreviewContent, settings: DockEnhanceSettings) {
        guard settings.shortcutsPreview, content.bundleID == "com.apple.shortcuts" else {
            shortcuts?.stop()
            shortcuts = nil
            content.shortcutsState = nil
            content.shortcutRuns = [:]
            return
        }
        guard shortcuts == nil else { return }
        let preview = makeShortcuts()
        shortcuts = preview
        preview.onChange = { [weak self, weak content, weak preview] in
            guard let self, let content, let preview else { return }
            content.shortcutsState = preview.state
            content.shortcutRuns = preview.runs
            self.onChange()
        }
        content.shortcutsState = .loading
        preview.start()
    }

    private func updateMessages(content: DockPreviewContent, settings: DockEnhanceSettings) {
        guard settings.messagesPreview, content.bundleID == "com.apple.MobileSMS" else {
            messages = nil
            content.messagesState = nil
            return
        }
        if messages == nil { messages = makeMessages() }
        content.messagesState = messages?.update(running: content.isRunning, badge: content.badge)
    }

    func tileChanged(badge: String?, running: Bool) {
        guard let content else { return }
        content.badge = badge
        content.isRunning = running
        if let messages {
            let state = messages.update(running: running, badge: badge)
            guard state != content.messagesState else { return }
            content.messagesState = state
            onChange()
        }
    }

    func badgeUnavailable() {
        guard let content, messages != nil else { return }
        let count: String?
        switch content.messagesState {
        case .unread(let value), .stale(.some(let value)): count = value
        default: count = nil
        }
        let state = DockMessagesPreview.State.stale(count)
        guard state != content.messagesState else { return }
        content.messagesState = state
        onChange()
    }

    func discardMailIfDisabled(_ settings: DockEnhanceSettings) {
        guard !settings.mailPreview else { return }
        discardMail()
    }

    func discardMail() {
        mail?.discard()
        mail = nil
        mailCache = nil
        mailCacheIsStale = false
        mailBadge = nil
        content?.mailState = nil
    }

    func badgeChanged(_ badge: String?) {
        guard let content, content.bundleID == DockEnhanceMath.mailBundleID else { return }
        content.badge = badge
        mail?.badgeChanged(badge)
    }

    func showMonth(_ month: Date) {
        guard let content, calendar.running else { return }
        content.calendarMonth = month
        content.calendarSelectedDay = month
        calendar.show(month: month)
    }

    func stop() {
        reminders?.stop()
        reminders = nil
        shortcuts?.stop()
        shortcuts = nil
        messages = nil
        content?.remindersState = nil
        content?.remindersWriteNotice = nil
        content?.shortcutsState = nil
        content?.shortcutRuns = [:]
        content?.messagesState = nil
        if let mail {
            mailCache = mail.cached
            mailCacheIsStale = mail.cacheIsStale
            mailBadge = content?.badge
        }
        mail?.discard()
        mail = nil
        content?.mailState = nil
        content?.music?.stop()
        content?.music = nil
        content?.musicPlayerEnabled = false
        content?.media = nil
        content?.mediaPending = false
        content?.calendarState = nil
        content = nil
        if let mediaToken { feed.unsubscribe(mediaToken) }
        mediaToken = nil
        calendar.stop()
    }

    func send(_ command: MediaRemoteBridge.Command) {
        if let music = content?.music { music.send(.transport(command)); return }
        guard mediaToken != nil, content?.media != nil else { return }
        feed.send(command)
    }

    func seek(to seconds: Double) {
        guard mediaToken != nil, content?.media != nil else { return }
        feed.seek(to: seconds)
    }
}
