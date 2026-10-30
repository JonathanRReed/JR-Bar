import AppKit
import JRBarCore
import JRBarTestSupport
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Dock preview size table and render proofs", .serialized, .renderProofAppearance)
struct DockPreviewSizeTests {
    struct Card {
        let name: String
        let view: AnyView
        var isMonth = false
    }

    private static let now = DockNativeAppCardTests.now

    private func cards() -> [Card] {
        let content = DockPreviewContent()
        let actions = DockPreviewActions(content: content)
        actions.onCalendarOpen = {}
        actions.onRemindersOpen = {}
        actions.onShortcutsOpen = {}
        let calendar = DockNativeAppCardTests.calendar
        let events = DockNativePreviewRenderProofTests.state("many")
        var result: [Card] = []
        for mode in DockCalendarView.allCases {
            let card = DockCalendarCard(state: events, now: Self.now, calendar: calendar,
                actions: actions, view: mode, month: Self.now, selectedDay: .constant(Self.now))
            result.append(Card(name: "calendar-\(mode.rawValue)", view: AnyView(card), isMonth: mode == .month))
        }
        // A six-week month is the tightest grid, even with no events.
        let sixWeeks = DockCalendarMonthTests.date(2020, 8, 15, calendar: calendar)
        result.append(Card(name: "calendar-six-weeks", view: AnyView(DockCalendarCard(
            state: .events([]), now: sixWeeks, calendar: calendar, actions: actions,
            view: .month, month: sixWeeks, selectedDay: .constant(sixWeeks))), isMonth: true))
        for mode in ["none", "no-access", "loading"] {
            let card = DockCalendarCard(state: DockNativePreviewRenderProofTests.state(mode), now: Self.now,
                calendar: calendar, actions: actions)
            result.append(Card(name: "calendar-\(mode)", view: AnyView(card)))
        }
        let selected = Self.now.addingTimeInterval(86400)
        result.append(Card(name: "calendar-day-list", view: AnyView(DockCalendarCard(
            state: events, now: Self.now, calendar: calendar, actions: actions,
            listDay: selected, selectedDay: .constant(selected)))))
        result.append(Card(name: "reminders-new", view: AnyView(DockRemindersCard(
            state: .items(DockNativeAppCardRenderProofTests.entries()), now: Self.now,
            actions: actions, adding: true, draft: "Water the plants"))))
        for mode in ["due", "long-title", "no-access", "denied", "stale", "empty", "loading"] {
            let card = DockRemindersCard(state: DockNativeAppCardRenderProofTests.reminderState(mode),
                now: Self.now, calendar: calendar, actions: actions)
            result.append(Card(name: "reminders-\(mode)", view: AnyView(card)))
        }
        for mode in ["list", "long-name", "unavailable", "stale", "empty", "loading"] {
            let card = DockShortcutsCard(state: DockNativeAppCardRenderProofTests.shortcutState(mode), actions: actions)
            result.append(Card(name: "shortcuts-\(mode)", view: AnyView(card)))
        }
        let runModes: [(String, DockShortcutsPreview.RunState)] = [
            ("running", .running), ("done", .done), ("failed", .failed), ("timed-out", .timedOut),
        ]
        for (name, run) in runModes {
            let names = ["Morning Brief", "Resize Images", "Start Focus Session", "Clean Downloads"]
            result.append(Card(name: "shortcuts-\(name)", view: AnyView(DockShortcutsCard(
                state: .shortcuts(names), runs: [names[0]: run], actions: actions))))
        }
        result.append(Card(name: "reminders-write-failed", view: AnyView(DockRemindersCard(
            state: .items(DockNativeAppCardRenderProofTests.entries()), now: Self.now,
            writeNotice: "Couldn't mark that reminder done. Open Reminders to try again.", actions: actions))))
        let entries = DockNativeAppCardRenderProofTests.entries()
        result.append(Card(name: "reminders-one", view: AnyView(DockRemindersCard(state: .items(Array(entries.prefix(1))), now: Self.now, actions: actions))))
        result.append(Card(name: "shortcuts-one", view: AnyView(DockShortcutsCard(state: .shortcuts(["Morning Brief"]), actions: actions))))
        let manyReminders = (0..<30).map { index in
            ShelfRemindersModel.Entry(id: "synthetic-\(index)", title: "Reminder \(index + 1)", due: Self.now)
        }
        result.append(Card(name: "reminders-many", view: AnyView(DockRemindersCard(state: .items(manyReminders), now: Self.now, actions: actions))))
        let manyShortcuts = (1...30).map { "Shortcut \($0)" }
        result.append(Card(name: "shortcuts-many", view: AnyView(DockShortcutsCard(state: .shortcuts(manyShortcuts), actions: actions))))
        result.append(Card(name: "media", view: AnyView(DockMediaRow(media: DockMusicTests.track(playing: false), actions: actions))))
        let windows = (0..<20).map { index in
            DockPreviewWindow(id: index, title: "Synthetic window \(index + 1)", minimized: false,
                              fullScreen: false, frame: nil, thumbnail: nil, element: nil)
        }
        result.append(Card(name: "compact-list", view: AnyView(DockPreviewCompactList(windows: windows, actions: actions))))
        return result
    }

    private func measure(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func table() {
        for size in DockPreviewSize.allCases {
            for card in cards() {
                let view = card.view.environment(\.dockPreviewSize, size)
                let measured = measure(view)
                #expect(abs(measured.width - size.contentWidth) <= 0.5, "\(card.name) at \(size): \(measured)")
                let limit = card.isMonth ? size.monthHeightLimit : size.widgetSize.height
                #expect(measured.height > 0 && measured.height <= limit + 0.5,
                        "\(card.name) at \(size): \(measured)")
            }
        }
    }

    @Test func sparseCardsDoNotReserveTheFullHeight() throws {
        for size in DockPreviewSize.allCases {
            var heights: [String: CGFloat] = [:]
            for card in cards() {
                heights[card.name] = measure(card.view.environment(\.dockPreviewSize, size)).height
            }
            for name in ["reminders-loading", "shortcuts-empty"] {
                let height = try #require(heights[name])
                #expect(height < size.widgetSize.height, "\(name) at \(size) reserved its full height")
            }
            let emptyShortcut = try #require(heights["shortcuts-empty"])
            let oneShortcut = try #require(heights["shortcuts-one"])
            #expect(emptyShortcut < oneShortcut)
            if size != .small {
                let list = try #require(heights["shortcuts-list"])
                #expect(oneShortcut < list)
            }
        }
    }

    @Test func nativePanelsAndExpandedWindowsStayUniform() {
        for size in DockPreviewSize.allCases {
            let content = DockPreviewContent()
            content.previewSize = size
            content.appName = "Reminders"
            content.remindersState = .items([])
            content.isRunning = true
            content.windows = DockPreviewSamples.terminal().windows
            let expected = size.widgetSize.width
            for expanded in [false, true] {
                content.nativeWindowsExpanded = expanded
                let panel = DockPreviewPanel(content: content)
                let measured = panel.fittingSize()
                #expect(abs(measured.width - expected) <= 0.5, "\(size), expanded \(expanded): \(measured)")
                #expect(measured.height <= size.maximumHeight)
                panel.close()
            }
        }
    }

    @Test func longListsKeepTheirViewportBelowTheHeaderAndCanScrollToTheEnd() throws {
        let rows = VStack(spacing: 4) {
            ForEach(0..<20, id: \.self) { _ in Text("Synthetic event").frame(height: 30) }
        }
        let view = VStack(spacing: 8) {
            Text("Header").frame(height: 24)
            DockContentList(maximumHeight: 120) { rows }
        }
        .frame(width: 300)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        window.setContentSize(fitted)
        host.setFrameSize(fitted)
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        let viewport = try #require(Self.scrollView(in: host))
        let document = try #require(viewport.documentView)
        let frame = viewport.convert(viewport.bounds, to: host)
        #expect(frame.minY >= 32)
        #expect(frame.maxY <= host.bounds.height + 0.5)
        #expect(abs(viewport.contentView.bounds.height - 120) < 0.5)
        #expect(document.frame.height > viewport.contentView.bounds.height)
        let end = CGPoint(x: 0, y: document.frame.height - viewport.contentView.bounds.height)
        viewport.contentView.scroll(to: end)
        viewport.reflectScrolledClipView(viewport.contentView)
        #expect(viewport.documentVisibleRect.minY > 0)
        #expect(abs(viewport.documentVisibleRect.maxY - document.frame.maxY) < 0.5)
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = scrollView(in: child) { return scroll }
        }
        return nil
    }

    @Test func musicSizeTable() async {
        let fixture = DockMusicTests.Fixture()
        fixture.reading = .init(media: DockMusicTests.track(), shuffle: true, repeatMode: .one, volume: 72, favorite: true)
        let player = fixture.makePlayer()
        player.start(fullControls: true)
        await player.settle()
        defer { player.stop() }
        let actions = DockPreviewActions(content: DockPreviewContent())
        for size in DockPreviewSize.allCases {
            let card = DockMusicCard(player: player, actions: actions).environment(\.dockPreviewSize, size)
            let measured = measure(card)
            #expect(measured.width == size.widgetSize.width)
            if size == .small { #expect(measured.height == size.widgetSize.height) }
            else { #expect(measured.height < size.widgetSize.height) }
        }
    }

    @Test func thumbnailTable() {
        for size in DockPreviewSize.allCases {
            #expect(DockEnhanceMath.cardSize(size: size) == size.thumbnail)
            let content = DockPreviewSamples.terminal()
            let window = content.windows[0]
            let actions = DockPreviewActions(content: content)
            let card = DockPreviewCard(window: window, icon: nil, size: size.thumbnail,
                                       metrics: size.metrics, actions: actions)
            let measured = measure(card.environment(\.dockPreviewSize, size))
            #expect(measured.width == size.thumbnail.width + 2 * size.innerPadding)
            #expect(measured.height <= size.maximumCardHeight)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func renderCards() throws {
        for size in DockPreviewSize.allCases {
            for dark in [false, true] {
                for card in cards() {
                    let view = card.view.environment(\.dockPreviewSize, size)
                        .background(Color(nsColor: .windowBackgroundColor))
                    try ProofRender.write(view, size: measure(view),
                        name: "\(card.name)-\(size.rawValue)-\(dark ? "dark" : "light")", dark: dark, settle: 0)
                }
                for compact in [false, true] {
                    let content = DockPreviewSamples.terminal()
                    content.previewSize = size
                    content.compact = compact
                    let view = DockPreviewView(content: content, actions: DockPreviewActions(content: content))
                        .background(Color(nsColor: .windowBackgroundColor))
                    let measured = measure(view)
                    let name = compact ? "window-list" : "window-strip"
                    try ProofRender.write(view, size: measured, name: "\(name)-\(size.rawValue)-\(dark ? "dark" : "light")", dark: dark, settle: 0)
                }
                let expanded = DockPreviewContent()
                expanded.windows = DockPreviewSamples.browser().windows
                expanded.isRunning = true
                expanded.previewSize = size
                expanded.appName = "Reminders"
                expanded.bundleID = "com.apple.reminders"
                expanded.remindersState = .items([])
                expanded.nativeWindowsExpanded = true
                let expandedActions = DockPreviewActions(content: expanded)
                expandedActions.onRemindersOpen = {}
                let expandedView = DockPreviewView(content: expanded, actions: expandedActions)
                    .background(Color(nsColor: .windowBackgroundColor))
                try ProofRender.write(expandedView, size: measure(expandedView),
                    name: "expanded-windows-\(size.rawValue)-\(dark ? "dark" : "light")", dark: dark, settle: 0)
                let picker = VStack(spacing: 12) {
                    DockPreviewSizePicker(selection: .constant(size))
                    HStack {
                        Text("Music")
                        Spacer()
                        DockPreviewSizeOverridePicker(name: "Music", selection: .constant(.large))
                    }
                    HStack {
                        Text("Calendar")
                        Spacer()
                        DockPreviewSizeOverridePicker(name: "Calendar", selection: .constant(.small))
                    }
                    HStack {
                        Text("Reminders")
                        Spacer()
                        DockPreviewSizeOverridePicker(name: "Reminders", selection: .constant(nil))
                    }
                }
                .padding(size.outerPadding).background(Color(nsColor: .windowBackgroundColor))
                try ProofRender.write(picker, size: CGSize(width: 440, height: 1),
                    name: "settings-\(size.rawValue)-\(dark ? "dark" : "light")", dark: dark, settle: 0)
                let sample = DockPreviewSample(previewSize: size, dockGap: 4, coversLabel: true, scale: 1)
                try ProofRender.write(sample, size: DockPreviewSample.desk,
                    name: "settings-sample-\(size.rawValue)-\(dark ? "dark" : "light")", dark: dark, settle: 0)
            }
        }
    }

}
