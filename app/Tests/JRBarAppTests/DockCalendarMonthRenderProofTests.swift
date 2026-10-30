import AppKit
import JRBarCore
import JRBarTestSupport
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Dock calendar month proofs", .serialized, .renderProofAppearance)
@MainActor
struct DockCalendarMonthProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func cards() throws {
        let cal = DockCalendarMonthTests.calendar("en_GB", zone: "UTC")
        let today = DockCalendarMonthTests.date(2024, 2, 14, 10, calendar: cal)
        let selected = DockCalendarMonthTests.date(2024, 2, 16, calendar: cal)
        let events = (0..<5).map { index in
            let hour = selected.addingTimeInterval(Double(9 + index) * 3600)
            return DockCalendarMonthTests.event(hour, hour.addingTimeInterval(3600),
                color: .init(red: Double(index) / 5, green: 0.4, blue: 0.8))
        }
        let todayEvent = DockCalendarMonthTests.event(today, today.addingTimeInterval(3600))
        for size in DockPreviewSize.allCases {
            for dark in [false, true] {
                for mode in ["events", "busy", "empty", "list", "day-list"] {
                    let content = DockPreviewContent()
                    let actions = DockPreviewActions(content: content)
                    actions.onCalendarOpen = {}
                    let sample = mode == "empty" ? [] : [todayEvent] + events
                    let selection = mode == "events" ? today : selected
                    let list = mode == "list" || mode == "day-list"
                    let card = DockCalendarCard(state: .events(sample), now: today, calendar: cal,
                        actions: actions, view: list ? .list : .month, month: today,
                        listDay: mode == "day-list" ? selected : nil,
                        selectedDay: .constant(selection), locale: Locale(identifier: "en_GB"))
                        .environment(\.dockPreviewSize, size)
                        .background(Color(nsColor: .windowBackgroundColor))
                    let host = NSHostingView(rootView: card)
                    host.layoutSubtreeIfNeeded()
                    let theme = dark ? "dark" : "light"
                    try ProofRender.write(card, size: host.fittingSize,
                        name: "calendar-grid-\(mode)-\(size.rawValue)-\(theme)", dark: dark, settle: 0)
                }
            }
        }
    }
}
