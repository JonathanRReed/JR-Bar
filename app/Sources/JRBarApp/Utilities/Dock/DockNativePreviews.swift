import Foundation
import JRBarCore
import EventKit

/// Readers belong to the visible preview, independently of the notch's subscriptions.
@MainActor
final class DockNativePreviews {
    let feed: MediaFeed
    let calendar: DockCalendarPreview
    var onChange: () -> Void = {}
    private var mediaToken: UUID?
    private weak var content: DockPreviewContent?

    init(feed: MediaFeed? = nil, calendar: DockCalendarPreview? = nil) {
        self.feed = feed ?? .shared
        self.calendar = calendar ?? DockCalendarPreview()
    }

    /// Seed the first frame from held values without starting either reader.
    func seed(content: DockPreviewContent, settings: DockEnhanceSettings) {
        let bundleID = content.bundleID
        content.media = settings.mediaPreview ? feed.media.flatMap {
            DockEnhanceMath.showsMediaRow(mediaBundleID: $0.bundleIdentifier, appBundleID: bundleID) ? $0 : nil
        } : nil
        content.mediaPending = settings.mediaPreview && content.isRunning && !feed.hasSnapshot
        content.calendarNow = calendar.clock()
        content.calendarView = settings.calendarView
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
        guard let content, let bundleID = content.bundleID else { return }
        content.mediaPending = settings.mediaPreview && content.isRunning && !feed.hasSnapshot
        if settings.mediaPreview, mediaToken == nil {
            mediaToken = feed.subscribe { [weak self, weak content] media in
                guard let self, let content else { return }
                content.mediaPending = content.isRunning && !self.feed.hasSnapshot
                content.media = media.flatMap {
                    DockEnhanceMath.showsMediaRow(mediaBundleID: $0.bundleIdentifier,
                                                 appBundleID: bundleID) ? $0 : nil
                }
                self.onChange()
            }
        } else if !settings.mediaPreview {
            if let mediaToken { feed.unsubscribe(mediaToken) }
            mediaToken = nil
            content.media = nil
        }
        let wantsCalendar = settings.calendarPreview &&
            (bundleID == DockEnhanceMath.calendarBundleID || DockEnhanceMath.isMeetingApp(bundleID))
        if wantsCalendar {
            content.calendarView = settings.calendarView
            let month = bundleID == DockEnhanceMath.calendarBundleID && settings.calendarView == .month
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
        onChange()
    }

    func showMonth(_ month: Date) {
        guard let content, calendar.running else { return }
        content.calendarMonth = month
        content.calendarSelectedDay = month
        calendar.show(month: month)
    }

    func stop() {
        content?.media = nil
        content?.mediaPending = false
        content?.calendarState = nil
        content = nil
        if let mediaToken { feed.unsubscribe(mediaToken) }
        mediaToken = nil
        calendar.stop()
    }

    func send(_ command: MediaRemoteBridge.Command) {
        guard mediaToken != nil, content?.media != nil else { return }
        feed.send(command)
    }

    func seek(to seconds: Double) {
        guard mediaToken != nil, content?.media != nil else { return }
        feed.seek(to: seconds)
    }
}
