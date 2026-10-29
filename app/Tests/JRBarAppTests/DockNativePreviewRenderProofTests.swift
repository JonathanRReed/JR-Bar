import AppKit
import JRBarCore
import JRBarTestSupport
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Dock native preview render proofs", .serialized, .renderProofAppearance)
struct DockNativePreviewRenderProofTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func event(_ title: String = "Design review", after: TimeInterval = 600,
                      allDay: Bool = false, location: String? = "Room 4") -> ShelfCalendarModel.Event {
        ShelfCalendarModel.Event(title: title, start: now.addingTimeInterval(after),
            end: now.addingTimeInterval(after + 3600), url: nil, isAllDay: allDay,
            calendarColor: .init(red: 0.25, green: 0.5, blue: 0.9), location: location)
    }

    static let calendarModes = ["none", "all-day", "ongoing", "many", "long-title", "no-access", "loading"]
    static func state(_ mode: String) -> DockCalendarPreview.State {
        switch mode {
        case "none": return .events([])
        case "all-day": return .events([event("Project day", after: -600, allDay: true)])
        case "ongoing": return .events([event(after: -600), event("Planning", after: 4000)])
        case "many": return .events((0..<12).map { event("Event \($0 + 1)", after: Double($0) * 4000) })
        case "long-title": return .events([event("Review the complete presentation and prepare the final illustrations for the afternoon workshop", location: "A very long location that should not be squeezed into this compact calendar preview card")])
        case "no-access": return .noAccess
        default: return .loading
        }
    }

    @Test("calendar content handles ended, all-day, ongoing, many and long events")
    func eventStates() {
        let ended = Self.event("Ended", after: -7200)
        let ongoing = Self.event("Ongoing", after: -600)
        let allDay = Self.event("All day", allDay: true)
        let rows = DockCalendarCard.upcoming([ended, allDay, ongoing], now: Self.now)
        #expect(rows.map(\.title) == ["Ongoing", "All day"])
        #expect(DockCalendarCard.upcoming([], now: Self.now).isEmpty)
        #expect(DockCalendarCard.upcoming((0..<20).map { Self.event(after: Double($0) * 600) }, now: Self.now).count == 6)
        #expect(DockCalendarCard.timeLine(allDay, now: Self.now, calendar: Self.utc) == "All day")
        #expect(DockCalendarCard.timeLine(ongoing, now: Self.now, calendar: Self.utc).hasPrefix("Now until "))
        let long = Self.event("A long title remains intact", location: String(repeating: "Location ", count: 20))
        #expect(long.title == "A long title remains intact")
        #expect(long.shortLocation == nil)
        #expect(Self.event(location: "Room 4").shortLocation == "Room 4")
        #expect(Self.event(location: "Floor 1\nRoom 4").shortLocation == nil)
        let overnight = ShelfCalendarModel.Event(title: "Overnight", start: Self.now.addingTimeInterval(-86_400),
            end: Self.now.addingTimeInterval(3600), url: nil, isAllDay: true)
        #expect(DockCalendarCard.isToday(overnight, now: Self.now, calendar: Self.utc))
        #expect(DockCalendarCard.timeLine(overnight, now: Self.now, calendar: Self.utc) == "All day")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func cards() throws {
        let actions = DockPreviewActions(content: DockPreviewContent())
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for mode in Self.calendarModes {
                let card = DockCalendarCard(state: Self.state(mode), now: Self.now,
                                            calendar: Self.utc, actions: actions)
                    .padding(14)
                    .background(dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
                try ProofRender.write(card, size: CGSize(width: 348, height: 110),
                    name: "dock-calendar-\(mode)-\(theme)", dark: dark, settle: 0)
            }
            for mode in ["playing", "paused", "no-artwork", "nothing-playing", "loading"] {
                let content = DockPreviewSamples.music()
                if mode == "nothing-playing" || mode == "loading" {
                    content.media = nil
                    if mode == "loading" {
                        content.mediaPending = true
                        content.windows = []
                    }
                } else {
                    content.media = AlcoveMedia(title: "Paper Lanterns", artist: "The Example Quartet",
                        playing: mode != "paused", artworkData: mode == "no-artwork" ? nil : Self.artwork(),
                        bundleIdentifier: "com.apple.Music", duration: 225, elapsed: 65,
                        timestamp: Date().timeIntervalSinceReferenceDate)
                }
                let scene = DockPreviewView(content: content, actions: DockPreviewActions(content: content))
                    .background(dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
                try ProofRender.write(scene, size: CGSize(width: 370, height: 180),
                    name: "dock-media-\(mode)-\(theme)", dark: dark, settle: 0)
            }
            let expandedMedia = DockPreviewSamples.music()
            expandedMedia.nativeWindowsExpanded = true
            let expandedScene = DockPreviewView(content: expandedMedia, actions: DockPreviewActions(content: expandedMedia))
                .background(dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
            try ProofRender.write(expandedScene,
                size: CGSize(width: 370, height: 220), name: "dock-media-windows-\(theme)", dark: dark, settle: 0)
            let full = DockPreviewSamples.music()
            full.media = nil
            full.appName = "Calendar"
            full.icon = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar")
            full.windows = [DockPreviewWindow(id: 1, title: "Calendar", minimized: false, fullScreen: nil,
                frame: CGRect(x: 0, y: 0, width: 600, height: 400), thumbnail: nil, element: nil, windowID: 1)]
            full.bundleID = "com.apple.iCal"
            full.calendarState = Self.state("ongoing")
            full.calendarNow = Self.now
            for windows in [false, true] {
                full.nativeWindowsExpanded = windows
                let scene = DockPreviewView(content: full, actions: DockPreviewActions(content: full))
                    .background(dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
                try ProofRender.write(scene, size: CGSize(width: 370, height: 220),
                    name: "dock-calendar-windows-\(windows)-\(theme)", dark: dark, settle: 0)
            }
        }
    }

    private static func artwork() -> Data? {
        let image = NSImage(size: CGSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 64, height: 64)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: 17, y: 17, width: 30, height: 30)).fill()
        image.unlockFocus()
        return image.tiffRepresentation
    }
}
