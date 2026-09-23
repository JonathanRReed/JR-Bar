import AppKit
import JRBarCore
import SwiftUI
import UniformTypeIdentifiers

/// The drop-down card's model — one instance behind `NotchCardPanel`,
/// filled by `NotchCardPresenter` from the band's focus pick plus the
/// island's session rows and meters.
@MainActor
@Observable
final class NotchCardModel {
    var focus = ScreenBarFocus(style: nil, label: "JR-Bar", word: "Idle", clickSession: nil)
    /// Pinned: the card holds open and its controls take clicks — a
    /// band click's deliberate focus, or the island's hover.
    var pinned = false {
        didSet {
            // The lens is a peek, not a standing row: folding the card
            // puts it away, and the next open starts without it.
            if !pinned { mirrorSummoned = false }
            guard runtimeEnabled else { return }
            if pinned {
                utility.start()
                tray.revalidate()
                tray.notePasteboard()
                mirror.sync(enabled: mirrorEnabled() && mirrorSummoned)
                calendar.sync(enabled: calendarEnabled())
                reminders.sync(enabled: remindersEnabled())
                wingHint = Self.wingHintDue()
            } else {
                utility.stop()
                calendar.stop()
                reminders.stop()
                mirror.sync(enabled: false)
            }
        }
    }
    /// The Mirror was asked for on this open — ⌥-click on the island, or
    /// the camera button in the pinned header. Only then does the lens
    /// open; the setting just makes it available.
    private(set) var mirrorSummoned = false

    /// The header's camera button: open or close the lens in place.
    func toggleMirror() {
        guard mirrorEnabled() else { return }
        setMirror(!mirrorSummoned)
    }

    /// Ask for the lens on this open — before the pin (it opens as the
    /// card lands) or after it (it opens in place).
    func summonMirror() {
        guard mirrorEnabled() else { return }
        setMirror(true)
    }

    private func setMirror(_ summoned: Bool) {
        mirrorSummoned = summoned
        if pinned, runtimeEnabled { mirror.sync(enabled: summoned) }
    }
    /// The one-line ear-gesture hint — drawn in the pinned card until
    /// the person has either flicked a wing once (the knowledge exists)
    /// or dismissed the line outright.
    var wingHint = false
    /// Marks the gesture vocabulary as learned — a real flick counts.
    static var wingGesturesUsed: Bool {
        get { UserDefaults.standard.bool(forKey: "jrbar.wingGesturesUsed") }
        set { UserDefaults.standard.set(newValue, forKey: "jrbar.wingGesturesUsed") }
    }
    private static var wingHintDismissed: Bool {
        UserDefaults.standard.bool(forKey: "jrbar.wingHintDismissed")
    }
    private static func wingHintDue() -> Bool {
        !wingGesturesUsed && !wingHintDismissed
    }
    func dismissWingHint() {
        wingHint = false
        UserDefaults.standard.set(true, forKey: "jrbar.wingHintDismissed")
    }
    /// The live sessions under the focus header — the island's rows
    /// minus the session the header already names.
    var rows: [NotchIslandRow] = []
    /// The headline quota meters (`NotchIsland.meters`); empty while
    /// the toy's `showUsage` is off.
    var meters: [NotchIslandMeter] = []
    /// Sessions working right now — the battery line says whether a run
    /// is riding on the charge.
    var workingCount = 0
    /// Whether the daemon holds the Mac awake (`state.power.keep_awake`).
    var heldAwake: () -> Bool = { false }
    /// Media/device utility facts — monitored only while pinned.
    let utility = ShelfUtilityModel()
    /// The file tray — paths persist in defaults; revalidated on pin.
    /// The two card surfaces (glass panel, grown island) share the one
    /// instance the delegate hands out: twin trays would race the same
    /// `jrbar.shelfTray.paths`.
    let tray: ShelfTrayModel
    /// Timers — tick and persist regardless of pin state so a deadline
    /// set now still fires after the card goes away. Shared for the
    /// same reason: twin models on `shelf-timers.json` would fire a
    /// timer twice and clobber each other's persist.
    let timers: ShelfTimerModel
    /// The calendar glance — reads only while pinned (privacy: no
    /// background polling of the owner's schedule).
    let calendar = ShelfCalendarModel()
    /// The reminders glance — same privacy rule as the calendar.
    let reminders = ShelfRemindersModel()
    /// The mirror row — the camera's own preview, live only while the
    /// card is pinned, the setting allows it, and this open asked for it
    /// (`mirrorSummoned`).
    let mirror = ShelfMirrorModel()
    /// The toys state's mirror vote — the presenter hands it through so
    /// a flip lands on the next pin without rebuilding the model.
    var mirrorEnabled: () -> Bool = { false }
    /// The Notch settings' Calendar and Reminders switches — read on
    /// every pin, so a flip lands on the next open.
    var calendarEnabled: () -> Bool = { true }
    var remindersEnabled: () -> Bool = { true }
    /// Where a session works — a reminder about it says so.
    var sessionCwd: (String) -> String? = { _ in nil }

    /// On a day with nothing on the calendar the weather takes the
    /// calendar's place — Alcove's empty-day conditions — instead of a
    /// "Nothing in the next 24 hours" line under a separate weather row.
    static func weatherTakesCalendarSlot(calendar: ShelfCalendarModel.State, hasWeather: Bool) -> Bool {
        hasWeather && calendar == .idle
    }
    var weatherInCalendarSlot: Bool {
        Self.weatherTakesCalendarSlot(calendar: calendar.state, hasWeather: utility.weather.reading != nil)
    }
    /// The island's content-follow gate: the expand starts with the
    /// rows hidden, and the frame spring reveals them once the frame
    /// has carried most of the way (`NotchMotion.contentRevealThreshold`)
    /// — frame leads, content follows. True at rest and under Reduce
    /// Motion, where the whole card is a single crossfade.
    var contentRevealed = true
    var onOpenSession: (() -> Void)?
    /// A click on a session row — that session's own window.
    var onOpenRow: ((String) -> Void)?
    /// Approve / Deny on a waiting row. nil draws no verbs: a card
    /// without an answer path only ever offers the click-to-open.
    var answerer: NotchAskAnswerer?
    var onClose: (() -> Void)?
    /// The roster affordance — the Overview window.
    var onOpenOverview: (() -> Void)?

    /// Headless state tests still exercise pin transitions, but must not
    /// start media, power, camera, calendar, or reminder readers.
    private let runtimeEnabled: Bool

    /// Who a shelf file can be handed to: the focus session first, then
    /// the card's other live sessions — never a peer's, whose terminal
    /// is on another Mac. Id and label, capped.
    var handTargets: [(id: String, label: String)] {
        var targets: [(id: String, label: String)] = []
        if let session = focus.clickSession, !CoreSession.isRemoteID(session) {
            targets.append((session, focus.label))
        }
        for row in rows where !CoreSession.isRemoteID(row.id) && !targets.contains(where: { $0.id == row.id }) {
            targets.append((row.id, row.label))
        }
        return Array(targets.prefix(5))
    }

    /// The shelf's hand-to-agent verb: the entry's `@path` references go
    /// on the pasteboard and the session's window comes forward, ready
    /// for the person's paste. Nothing is ever typed for them.
    func handToAgent(_ entry: ShelfTrayModel.ShelfEntry, session: String) {
        guard tray.copyForAgent(entry) else { return }
        onOpenRow?(session)
    }

    /// Files dropped straight onto a session row — the same hand-off,
    /// without a stop in the tray.
    func handFiles(_ urls: [URL], session: String) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty, !CoreSession.isRemoteID(session) else { return }
        ShelfTrayModel.copyForAgent(files, attachImage: files.count == 1
                                    && ShelfTrayModel.withinAttachBound(files[0]))
        onOpenRow?(session)
    }

    init(timers: ShelfTimerModel, tray: ShelfTrayModel,
         runtimeEnabled: Bool = true) {
        self.timers = timers
        self.tray = tray
        self.runtimeEnabled = runtimeEnabled
    }
}

/// Where the card renders: `glass` floats detached under the band on
/// `NSGlassEffectView`, so semantic label colours stand; `island` is
/// grown out of the notch itself on solid black, where they would sink
/// — its colours are white by opacity instead.
enum NotchCardStyle { case glass, island }

extension NotchCardStyle {
    /// Headline text.
    var titleColor: Color { self == .island ? .white : .primary }
    /// Secondary copy.
    var subColor: Color { self == .island ? .white.opacity(0.58) : .secondary }
    /// Tertiary copy — facts that may whisper.
    var faintColor: Color {
        self == .island ? .white.opacity(0.36) : Color(nsColor: .tertiaryLabelColor)
    }
    /// Chip and meter-well fills.
    var chipFill: Color {
        self == .island ? .white.opacity(0.14) : Color(nsColor: .quaternaryLabelColor)
    }
    /// A chip that should read as faded, not tappable.
    var chipFaint: Color { self == .island ? .white.opacity(0.07) : .primary.opacity(0.05) }
}

/// The one card under the notch. A band hover shows it as a peek — the
/// focus header only; pinned, or held open from the island, it is the
/// full surface: focus, the other live sessions, the shelf rows, the
/// meters and the roster button. Every row renders only while it has
/// something to say.
struct NotchCardView: View {
    @Bindable var model: NotchCardModel
    var style: NotchCardStyle = .glass
    /// The card's width — fixed on glass, the slot's measure on the
    /// island.
    var width: CGFloat = NotchCardView.width
    /// The custom-timer popover — `ViewState`, not `@State`: the
    /// Command Line Tools ship no `SwiftUIMacros` plugin.
    @ViewState private var timerEntryShown = false
    @ViewState private var timerEntryName = ""
    @ViewState private var timerEntryMinutes = 10

    /// Narrow enough to read as the notch's own drop-down, wide enough
    /// for a session label.
    static let width: CGFloat = 320

    /// The add-a-timer presets, in the pinned header's "+" — bounded by
    /// `ShelfTimerModel.maxDuration` regardless.
    static let timerPresets: [(name: String, seconds: TimeInterval)] = [
        ("1 minute", 60), ("5 minutes", 300), ("15 minutes", 900),
        ("30 minutes", 1800), ("1 hour", 3600),
    ]

    /// The island's card hugs the notch — a touch tighter than glass.
    private var verticalPad: CGFloat { style == .island ? 6 : 8 }
    /// The Screen Bar window sits above the island and backs its 28 pt
    /// bottom corners. Keep the footer two points above that black layer.
    static let islandBottomContentInset = NotchSilhouetteGeometry.maximumExpandedRadius + 2

    var body: some View {
        if model.pinned {
            card
        } else {
            // The peek is a glance: the header alone, still padded so
            // the provider tile never clips the card's edge.
            focusHeader(pinned: false)
                .padding(.horizontal, 12)
                .padding(.vertical, verticalPad)
                .fixedSize()
        }
    }

    /// One row's content-follow fade: hidden until the frame has
    /// carried the expand, then in on its own stagger — frame leads,
    /// content follows (`NotchMotion.rowStagger`/`rowFade`).
    private func revealRow<V: View>(_ index: Int, _ content: V) -> some View {
        content
            .opacity(model.contentRevealed ? 1 : 0)
            .animation(.easeOut(duration: NotchMotion.rowFade)
                .delay(Double(index) * NotchMotion.rowStagger),
                       value: model.contentRevealed)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            revealRow(0, focusHeader(pinned: true))
            if model.wingHint { revealRow(1, wingHintRow) }
            if !model.rows.isEmpty {
                ForEach(Array(model.rows.prefix(NotchIsland.rowLimit).enumerated()),
                        id: \.element.id) { index, row in
                    revealRow(2 + index, sessionRow(row))
                }
                if model.rows.count > NotchIsland.rowLimit {
                    revealRow(8, Text("+\(model.rows.count - NotchIsland.rowLimit) more")
                        .font(.system(size: 10))
                        .foregroundStyle(style.faintColor)
                        .padding(.leading, 24))
                }
            }
            revealRow(9, ShelfMediaRow(utility: model.utility, style: style))
            revealRow(10, ShelfBatteryRow(power: model.utility.power, working: model.workingCount,
                                          heldAwake: model.heldAwake(), style: style))
            if !model.weatherInCalendarSlot {
                revealRow(11, ShelfWeatherRow(weather: model.utility.weather, style: style))
            }
            revealRow(12, ShelfTrayRow(tray: model.tray, style: style,
                                       handTargets: model.handTargets,
                                       onHand: { entry, session in
                                           model.handToAgent(entry, session: session)
                                       }))
            if !model.timers.entries.isEmpty {
                revealRow(13, ShelfTimersRow(timers: model.timers, style: style))
            }
            if model.weatherInCalendarSlot {
                revealRow(14, ShelfWeatherRow(weather: model.utility.weather, style: style))
            } else {
                revealRow(14, ShelfCalendarRow(calendar: model.calendar, style: style))
            }
            revealRow(15, ShelfRemindersRow(reminders: model.reminders, style: style))
            revealRow(16, ShelfMirrorRow(mirror: model.mirror, style: style))
            revealRow(17, ShelfTogglesRow(toggles: model.utility.toggles, style: style))
            if !model.meters.isEmpty {
                ForEach(Array(model.meters.enumerated()), id: \.element.id) { index, meter in
                    revealRow(18 + index, meterRow(meter))
                }
            }
            revealRow(22, overviewButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPad)
        .padding(.bottom, style == .island
            ? Self.islandBottomContentInset - verticalPad : 0)
        .frame(width: width)
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.plainText], isTargeted: nil) { providers in
            ShelfTrayDrop.urls(from: providers) { urls in
                model.tray.add(urls)
            }
            return true
        }
    }

    /// The ear-gesture vocabulary in one line — the marks-only ears
    /// cannot explain themselves, and nothing else says they take
    /// flicks. Stays until a real flick lands or the × sends it away.
    private var wingHintRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(style.faintColor)
            Text("Flick an ear outward to hide it · swipe the bar sideways to bring it back")
                .font(.system(size: 10))
                .foregroundStyle(style.faintColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { model.dismissWingHint() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(style.faintColor)
            }
            .buttonStyle(.plain)
            .help("Don't show this hint again")
        }
    }

    /// The header row: who the bar is about — provider tile, label,
    /// word — with the light's reason underneath. Pinned adds the
    /// card's controls on the trailing edge: the timer menu, Open for
    /// the named session, and close.
    private func focusHeader(pinned: Bool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            if let style = model.focus.style {
                ProviderTile(style: style, size: 16)
            } else {
                Image(nsImage: StatusItemController.glyph())
                    .renderingMode(.template)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.focus.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(style.titleColor)
                        .lineLimit(1)
                    Text("·").foregroundStyle(style.faintColor)
                    Text(model.focus.word)
                        .font(.system(size: 12))
                        .foregroundStyle(style.subColor)
                        .lineLimit(1)
                }
                if let explanation = model.focus.explanation {
                    Text(explanation)
                        .font(.system(size: 10.5))
                        .foregroundStyle(style.faintColor)
                        .lineLimit(1)
                }
            }
            if pinned {
                Spacer(minLength: 4)
                // The deliberate-focus controls: the timer menu keeps the
                // row hidden when empty reachable, Open raises the
                // session's terminal, ✕ lets the card go.
                HStack(spacing: 4) {
                    Menu {
                        ForEach(Self.timerPresets, id: \.seconds) { preset in
                            Button(preset.name) {
                                model.timers.add(label: preset.name, duration: preset.seconds)
                            }
                        }
                        Divider()
                        Button("Custom…") { timerEntryShown = true }
                    } label: {
                        Image(systemName: "timer")
                            .font(.system(size: 9))
                            .foregroundStyle(style.faintColor)
                            .frame(width: 16, height: 16)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 20)
                    .help("Add a timer")
                    .popover(isPresented: $timerEntryShown, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Custom timer")
                                .font(.system(size: 11, weight: .semibold))
                            TextField("Label (optional)", text: $timerEntryName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                            Stepper(value: $timerEntryMinutes, in: 1...720, step: 1) {
                                Text("\(timerEntryMinutes) min")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                            }
                            HStack {
                                Spacer()
                                Button("Start") {
                                    let name = timerEntryName
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                    model.timers.add(
                                        label: name.isEmpty
                                            ? "\(timerEntryMinutes)-minute timer" : name,
                                        duration: TimeInterval(timerEntryMinutes) * 60)
                                    timerEntryShown = false
                                    timerEntryName = ""
                                }
                                .keyboardShortcut(.defaultAction)
                                .controlSize(.small)
                            }
                        }
                        .padding(10)
                        .frame(width: 200)
                    }
                    // The Mirror is a peek on demand, never a standing
                    // row: the lens opens here (or on ⌥-click at the
                    // notch) and closes with the card.
                    if model.mirrorEnabled() {
                        Button { model.toggleMirror() } label: {
                            Image(systemName: model.mirrorSummoned ? "camera.fill" : "camera")
                                .font(.system(size: 9))
                                .foregroundStyle(model.mirrorSummoned ? style.titleColor : style.faintColor)
                                .frame(width: 16, height: 16)
                        }
                        .help(model.mirrorSummoned ? "Close the mirror" : "Mirror — a quick look through the camera")
                        .accessibilityLabel(model.mirrorSummoned ? "Close the mirror" : "Open the mirror")
                    }
                    if model.focus.clickSession != nil {
                        Button("Open") { model.onOpenSession?() }
                            .controlSize(.mini)
                    }
                    Button { model.onClose?() } label: {
                        Image(systemName: "xmark")
                    }
                    .controlSize(.mini)
                    .accessibilityLabel("Close pinned card")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// One live session under the header: the provider's dot, its label,
    /// and the same activity word the island would say. A click opens
    /// the session. A waiting row the daemon can answer carries Deny and
    /// Approve inline instead of the word (`NotchAskVerbs` — hidden
    /// where the answer chain cannot deliver), with the question itself
    /// on a faint second line; a refused answer takes that line and
    /// says why, and the ask stays open.
    private func sessionRow(_ row: NotchIslandRow) -> some View {
        let verbs = row.activity == .waiting
            ? NotchAskVerbs.resolve(live: row.ask, session: row.id) : .none
        let answerer = model.answerer
        let pending = answerer?.isPending(row.id) ?? false
        let second = answerer?.note(for: row.id)
            ?? row.ask?.summary.flatMap { $0.isEmpty ? nil : $0 }
        let opens = !CoreSession.isRemoteID(row.id) && model.onOpenRow != nil
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .fill(ProviderStyle.style(for: row.provider).accent)
                    .frame(width: 5, height: 5)
                Text(row.label)
                    .font(.system(size: 11))
                    .foregroundStyle(style == .island ? .white.opacity(0.85) : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if verbs.answers, let answerer {
                    NotchVerbButton(title: "Deny", style: style, prominent: false,
                                    busy: pending) {
                        Task { await answerer.answer(session: row.id, ask: row.ask, approve: false) }
                    }
                    NotchVerbButton(title: "Approve", style: style, prominent: true,
                                    busy: pending) {
                        Task { await answerer.answer(session: row.id, ask: row.ask, approve: true) }
                    }
                } else {
                    Text(row.activity.word)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(row.activity.wordColor)
                }
            }
            if let second {
                Text(second)
                    .font(.system(size: 9.5))
                    .foregroundStyle(answerer?.note(for: row.id) != nil
                                     ? AnyShapeStyle(Color.orange) : AnyShapeStyle(style.faintColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 11)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if opens { model.onOpenRow?(row.id) }
        }
        // Drag a screenshot to the notch and let go on the agent: the
        // file's `@path` is on the pasteboard and its session comes up.
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard opens else { return false }
            ShelfTrayDrop.urls(from: providers) { urls in
                model.handFiles(urls, session: row.id)
            }
            return true
        }
        .contextMenu {
            if opens {
                Button("Open \(row.label)") { model.onOpenRow?(row.id) }
            }
            // A timer about the run itself: it only speaks if the
            // session is still working when it comes due.
            if row.activity == .working {
                Button("Nudge Me in 20 Min If Still Working") {
                    model.timers.add(label: "\(row.label) still working", duration: 20 * 60,
                                     watchSession: row.id)
                }
            }
            // "I'll look at that later", kept: a reminder that names the
            // run and where it ran, due when the person says.
            if model.reminders.canWrite {
                Menu("Remind Me About This") {
                    ForEach(ShelfRemindersModel.Later.allCases, id: \.self) { later in
                        Button(later.title) {
                            model.reminders.remind(about: row.label, provider: row.provider,
                                                   cwd: model.sessionCwd(row.id), later: later)
                        }
                    }
                }
            }
        }
        .help(opens ? "Open \(row.label)" : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.label), \(row.activity.word)")
    }

    /// One quota meter: provider, window, a short bar, the percent —
    /// with the reset countdown the ear's drain arc only hints at, and
    /// the status feed's incident mark when the vendor is having a day.
    private func meterRow(_ meter: NotchIslandMeter) -> some View {
        HStack(spacing: 6) {
            Text(ProviderStyle.style(for: meter.provider).name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(style.subColor)
                .lineLimit(1)
            Text(meter.window)
                .font(.system(size: 9))
                .foregroundStyle(style.faintColor)
            if let countdown = PanelStore.countdown(to: meter.resetsAt, now: Date()) {
                Text(countdown)
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(style.faintColor)
                    .lineLimit(1)
            }
            if meter.incident {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help("The provider's status feed reports an incident")
            }
            Spacer(minLength: 4)
            Capsule()
                .fill(style.chipFill)
                .frame(width: 48, height: 4)
                .overlay(alignment: .leading) {
                    if let percent = meter.percent {
                        Capsule()
                            .fill(ProviderStyle.style(for: meter.provider).accent)
                            .frame(width: 48 * min(1, max(0, percent / 100)), height: 4)
                    }
                }
            Text(meter.percentText)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(style.subColor)
                .frame(width: 30, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .contextMenu {
            // A timer set to the window's own reset — "tell me when I
            // can go again" without watching a countdown.
            if let resetsAt = meter.resetsAt,
               Date(timeIntervalSince1970: resetsAt).timeIntervalSinceNow <= ShelfTimerModel.maxDuration {
                Button("Remind Me When \(meter.window) Resets") {
                    model.timers.add(label: "\(ProviderStyle.style(for: meter.provider).name) \(meter.window) reset",
                                     until: Date(timeIntervalSince1970: resetsAt))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var overviewButton: some View {
        Button { model.onOpenOverview?() } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(style.subColor)
                    .frame(width: 18, height: 18)
                Text("Agent Overview")
                    .font(.system(size: 11))
                    .foregroundStyle(style.subColor)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Every session as a roster (⌘O)")
    }
}

/// The card's media row: artwork, source identity, track line,
/// transport. Drawn only while a certified source reports media —
/// `nil` media means no row, not a dead control.
private struct ShelfMediaRow: View {
    let utility: ShelfUtilityModel
    let style: NotchCardStyle

    var body: some View {
        if let media = utility.media {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Group {
                        if let artwork = utility.artwork {
                            Image(nsImage: artwork)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(style.subColor)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { utility.raisePlayer() }
                    .help(utility.sourceName.map { "Open \($0)" } ?? "")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(media.displayLine)
                            .font(.system(size: 11))
                            .foregroundStyle(style.titleColor)
                            .lineLimit(1)
                        Text(utility.sourceName ?? "Now playing")
                            .font(.system(size: 9))
                            .foregroundStyle(style.faintColor)
                            .lineLimit(1)
                    }
                    if media.playing {
                        if utility.audioTapLive {
                            LiveEqualizer(levels: utility.audioLevels,
                                          color: style.faintColor)
                        } else {
                            ShelfEqualizer(color: style.faintColor)
                        }
                    }
                    Spacer(minLength: 4)
                    transportButton("backward.fill") { utility.send(.previousTrack) }
                    transportButton(media.playing ? "pause.fill" : "play.fill") {
                        utility.send(.togglePlayPause)
                    }
                    transportButton("forward.fill") { utility.send(.nextTrack) }
                }
                if let duration = media.duration, duration > 1,
                   media.elapsed != nil {
                    TimelineView(.periodic(from: .now, by: media.playing ? 0.5 : 30)) { context in
                        HStack(spacing: 6) {
                            Text(Self.clock(utility.elapsedShown(at: context.date)))
                                .font(.system(size: 9))
                                .monospacedDigit()
                                .foregroundStyle(style.faintColor)
                            Slider(value: Binding(
                                    get: { utility.elapsedShown(at: context.date) },
                                    set: { utility.mediaScrub = $0 }),
                                   in: 0...duration) { editing in
                                if editing {
                                    utility.beginScrub()
                                } else {
                                    utility.commitScrub()
                                }
                            }
                            .controlSize(.mini)
                            Text("−" + Self.clock(duration - utility.elapsedShown(at: context.date)))
                                .font(.system(size: 9))
                                .monospacedDigit()
                                .foregroundStyle(style.faintColor)
                        }
                    }
                }
                if let synced = utility.lyrics.lyrics {
                    LyricLines(lyrics: synced, utility: utility, playing: media.playing, style: style)
                }
                if let volume = utility.outputVolume {
                    // Fine adjustment without the keys — the same
                    // CoreAudio path the level HUD reads.
                    HStack(spacing: 6) {
                        Image(systemName: volume <= 0 ? "speaker.slash.fill" : "speaker.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(style.faintColor)
                            .frame(width: 12)
                        Slider(value: Binding(get: { volume }, set: { utility.setVolume($0) }),
                               in: 0...1)
                            .controlSize(.mini)
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(style.faintColor)
                    }
                    .accessibilityLabel("Volume")
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func transportButton(_ symbol: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(style.subColor)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The synced lyrics under the transport — Atoll's sweep in the card's
/// own restraint: the current line bright with a soft highlight
/// travelling through it in time, the next line faint beneath. The
/// clock runs on the display (30 fps) only while the row is mounted
/// and the track plays; paused, or under Reduce Motion, it steps at a
/// calm rate and the sweep stands still. Silent between stamps.
private struct LyricLines: View {
    let lyrics: SyncedLyrics
    let utility: ShelfUtilityModel
    let playing: Bool
    let style: NotchCardStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let live = playing && !reduceMotion
        TimelineView(.animation(minimumInterval: live ? 1.0 / 30.0 : 0.5, paused: !playing)) { context in
            let at = utility.elapsedShown(at: context.date)
            let position = lyrics.position(at: at)
            VStack(alignment: .leading, spacing: 1) {
                if let line = lyrics.line(at: at) {
                    Text(line)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(style.subColor)
                        .overlay {
                            if live, let progress = position.progress {
                                // The sweep: the same text, brighter,
                                // revealed left to right as the line plays.
                                Text(line)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(style.titleColor)
                                    .mask(alignment: .leading) {
                                        GeometryReader { geo in
                                            Rectangle().frame(width: geo.size.width * progress)
                                        }
                                    }
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let next = position.next {
                    Text(next)
                        .font(.system(size: 9))
                        .foregroundStyle(style.faintColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The Control Center strip — One Switch's row as card grammar: eight
/// chips, lit while on, dimmed while off, verbs that never latch.
/// The state is read back from the system after every apply — a chip
/// only ever shows what the Mac reports, and a refused write says so
/// in a caption under the row rather than silently staying lit.
private struct ShelfTogglesRow: View {
    let toggles: SystemTogglesStore
    let style: NotchCardStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                ForEach(SystemToggle.allCases, id: \.rawValue) { toggle in
                    chip(toggle)
                }
            }
            if let error = toggles.lastError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(style.faintColor)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func chip(_ toggle: SystemToggle) -> some View {
        let on = toggles.isOn[toggle] ?? false
        let busy = toggles.applying.contains(toggle)
        return Button {
            toggles.apply(toggle)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: toggle.symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(toggle.title)
                    .font(.system(size: 7, weight: .medium))
            }
            .foregroundStyle(on ? style.titleColor : style.faintColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? AnyShapeStyle(style.chipFill)
                             : AnyShapeStyle(style.chipFaint)))
            .opacity(busy ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(for: toggle, on: on))
        .accessibilityLabel("\(toggle.title) toggle")
        .accessibilityValue(toggle.isMomentary ? "action" : (on ? "on" : "off"))
    }

    /// The chip's tooltip — the verb, the honest restart warning, and
    /// the current truth for stateful toggles.
    private func help(for toggle: SystemToggle, on: Bool) -> String {
        switch toggle {
        case .keepAwake:
            return on ? "Keeping the Mac awake — click to allow sleep."
                        : "Keep the Mac awake (power assertion; releases when off or the app quits)."
        case .darkMode:
            return on ? "Dark mode is on — click for light."
                        : "Switch to dark mode."
        case .desktopIcons:
            return on ? "Desktop icons visible — click to hide (restarts Finder)."
                        : "Show desktop icons (restarts Finder)."
        case .hiddenFiles:
            return on ? "Hidden files visible — click to conceal (restarts Finder)."
                        : "Show hidden files (restarts Finder)."
        case .mute:
            return on ? "Output muted — click to unmute."
                        : "Mute the default output."
        case .screenSaver:
            return "Start the screen saver."
        case .lock:
            return "Sleep the display — locks on wake wherever a password is required."
        case .dockAutoHide:
            return on ? "Dock auto-hides — click to pin it (restarts Dock)."
                        : "Auto-hide the Dock (restarts Dock)."
        }
    }
}

/// The playing tell: five bars breathing on staggered phases — the
/// honest version of the notch apps' visualizer when no audio tap is
/// running (the setting off, consent not granted, the pipeline down):
/// it marks "something is playing", not a real spectrum.
private struct ShelfEqualizer: View {
    let color: Color
    private let phases: [Double] = [0.0, 0.35, 0.7, 0.25, 0.55]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.22)) { context in
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(phases.indices, id: \.self) { i in
                    let t = context.date.timeIntervalSinceReferenceDate * 3 + phases[i] * .pi * 2
                    let h = 4 + 6 * abs(sin(t))
                    RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                        .fill(color)
                        .frame(width: 2.2, height: h)
                }
            }
            .frame(height: 10, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// The real visualizer: six bars driven by the tap's band levels.
/// The model publishes at ~30 Hz so plain reads animate themselves;
/// under Reduce Motion the bars stand still and re-read at 2 Hz.
private struct LiveEqualizer: View {
    let levels: [Float]
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                bars
            }
        } else {
            bars
        }
    }

    private var bars: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(levels.indices, id: \.self) { i in
                let level = CGFloat(min(1, max(0, levels[i])))
                RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                    .fill(color)
                    .frame(width: 2.2, height: 2.5 + 7.5 * level)
            }
        }
        .frame(height: 10, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// The card's battery row: the internal battery's observed state,
/// hidden entirely on machines without one — never an invented charge.
/// The glyph holds the charge it reads, and the line is agent-aware:
/// the system's time estimate, how many runs ride on it, and whether
/// the Mac is held awake (`AlcovePower.batteryLine`) — whether a long
/// run survives unplugged is the question only this card can answer.
private struct ShelfBatteryRow: View {
    let power: AlcovePowerState
    let working: Int
    let heldAwake: Bool
    let style: NotchCardStyle

    var body: some View {
        if power.hasBattery {
            let low = !power.onAC && (power.percent ?? 100) < AlcovePower.lowThreshold
            HStack(spacing: 6) {
                Image(systemName: power.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(low ? AnyShapeStyle(Color.orange) : AnyShapeStyle(style.subColor))
                    .frame(width: 18)
                Text(AlcovePower.batteryLine(power, working: working, heldAwake: heldAwake))
                    .font(.system(size: 11))
                    .foregroundStyle(style.subColor)
                    .lineLimit(1)
            }
        }
    }
}

/// The card's weather row: the Open-Meteo reading beside the battery —
/// symbol, temperature, the place the reading is for — over a faint
/// outlook line (today's high and low, rain in the next two hours in a
/// cool tint). Absent while the setting is off or no fetch has landed;
/// the row never invents a sky.
private struct ShelfWeatherRow: View {
    let weather: NotchWeather
    let style: NotchCardStyle

    var body: some View {
        if let reading = weather.reading {
            let (symbol, label) = NotchWeather.symbol(for: reading.code)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(style.subColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text([label, reading.temperatureText, reading.place]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(style.subColor)
                        .lineLimit(1)
                    if let outlook = reading.outlookText {
                        Text(outlook)
                            .font(.system(size: 9.5))
                            .foregroundStyle(reading.rainInMinutes != nil
                                             ? AnyShapeStyle(Color.cyan.opacity(0.85))
                                             : AnyShapeStyle(style.faintColor))
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

/// The card's tray strip: dropped files as chips. A moved or deleted
/// file renders dimmed and disabled — the strip says missing, it
/// doesn't silently forget. Reveal/share only ever act on a file that
/// re-resolved this pass. "Hand to" gives a file to an agent: its
/// `@path` goes on the pasteboard and that session comes forward.
private struct ShelfTrayRow: View {
    let tray: ShelfTrayModel
    let style: NotchCardStyle
    var handTargets: [(id: String, label: String)] = []
    var onHand: (ShelfTrayModel.ShelfEntry, String) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !tray.entries.isEmpty || tray.pasteOffered {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        if tray.pasteOffered { pasteChip }
                        ForEach(tray.entries) { entry in
                            trayChip(entry)
                        }
                    }
                }
                .frame(maxWidth: 280)
            }
            if let notice = tray.evictionNotice {
                Text(notice)
                    .font(.system(size: 8))
                    .foregroundStyle(style.faintColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 280, alignment: .leading)
                    .task(id: notice) {
                        // Fades on its own; the next add/remove clears
                        // it outright.
                        try? await Task.sleep(for: .seconds(8))
                        tray.clearEvictionNotice()
                    }
            }
        }
    }

    /// Yoink's keyboard-free save: something copied since the last
    /// paste here can join the shelf in one click.
    private var pasteChip: some View {
        Button { tray.paste() } label: {
            HStack(spacing: 3) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 9))
                Text("Paste")
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(style.subColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(style.chipFill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Put what you copied on the shelf")
        .accessibilityLabel("Paste to the shelf")
    }

    private func trayChip(_ entry: ShelfTrayModel.ShelfEntry) -> some View {
        Group {
            switch entry {
            case .item(let item):
                itemFace(item, entry: entry)
            case .stack(let stack):
                ShelfStackChip(tray: tray, stack: stack, style: style) {
                    tray.dissolve(entry)
                }
            }
        }
        .contextMenu {
            if !entry.missing {
                // The job done all day: a screenshot or a file handed
                // to an agent — copied as its `@path`, the session raised
                // for the paste. Never typed for you.
                if let first = handTargets.first {
                    Button("Hand to \(first.label)") { onHand(entry, first.id) }
                    if handTargets.count > 1 {
                        Menu("Hand to") {
                            ForEach(handTargets, id: \.id) { target in
                                Button(target.label) { onHand(entry, target.id) }
                            }
                        }
                    }
                    Divider()
                }
                Button("Quick Look") { tray.quickLook(entry) }
                Button("Reveal in Finder") { tray.reveal(entry) }
                Button("Send via AirDrop") { _ = tray.sendViaAirDrop(entry) }
                shareMenu(for: entry)
            }
            switch entry {
            case .item:
                if tray.entries.firstIndex(where: { $0.id == entry.id })
                    .map({ $0 + 1 < tray.entries.count }) == true {
                    Button("Merge with Next") {
                        tray.mergeWithNext(entry)
                    }
                }
            case .stack:
                Button("Split into Items") { tray.dissolve(entry) }
            }
            Button("Remove from Tray", role: .destructive) { tray.remove(entry) }
        }
        .onDrag {
            tray.provider(for: entry) ?? NSItemProvider()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // No provider carrying a file means nothing to land —
            // an unconditional yes would animate acceptance anyway.
            guard providers.contains(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }) else { return false }
            // A tray drag carries the entry's own file URLs: landing on
            // another chip reorders; a foreign file lands where it
            // dropped — onto a stack it joins the stack, anywhere else
            // it lands ahead of the chip (Yoink's move, not the tail).
            ShelfTrayDrop.urls(from: providers) { urls in
                var toAdd: [URL] = []
                for url in urls {
                    if let moved = tray.entries.first(where: {
                        $0.items.contains(where: { $0.path == url.path })
                    }) {
                        tray.move(moved, before: entry)
                    } else {
                        toAdd.append(url)
                    }
                }
                if !toAdd.isEmpty {
                    if case .stack = entry {
                        tray.add(toAdd, onto: entry)
                    } else {
                        tray.add(toAdd, before: entry)
                    }
                }
            }
            return true
        }
        .help(entry.missing
              ? "Missing — the file moved or was deleted."
              : entry.items.first?.path ?? entry.displayName)
    }

    /// A loose file's chip face — the Finder icon and the name;
    /// double-click previews. Tap handling lives on the chip's own
    /// gestures so a stack can answer a plain click with its grid.
    private func itemFace(_ item: ShelfTrayModel.Entry,
                          entry: ShelfTrayModel.ShelfEntry) -> some View {
        HStack(spacing: 3) {
            if item.missing {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 9))
            } else {
                // The file's own Finder face — Yoink's tray grammar,
                // not a generic glyph.
                Image(nsImage: tray.icon(for: item))
                    .resizable()
                    .frame(width: 11, height: 11)
            }
            Text(item.missing ? "\(item.name) (moved)" : item.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(item.missing
                    ? AnyShapeStyle(style.chipFaint)
                    : AnyShapeStyle(style.chipFill),
                    in: Capsule())
        .foregroundStyle(item.missing ? style.faintColor : style.subColor)
        .onTapGesture(count: 2) {
            if !item.missing { tray.quickLook(entry) }
        }
    }

    /// Native share targets for the entry's files; a canceled sheet
    /// delivers nothing and claims nothing.
    private func shareMenu(for entry: ShelfTrayModel.ShelfEntry) -> some View {
        Menu("Share…") {
            ForEach(tray.sharingServices(for: entry), id: \.title) { service in
                Button(service.title) {
                    service.perform(withItems: entry.items
                        .filter { !$0.missing }.map(\.url))
                }
            }
        }
    }
}

/// A stack's chip: a fan of its first three icons, the name and the
/// count. A plain click opens the grid popover; ⌘-click dissolves
/// the stack where it stands.
private struct ShelfStackChip: View {
    let tray: ShelfTrayModel
    let stack: ShelfTrayModel.ShelfEntry.Stack
    let style: NotchCardStyle
    let dissolve: () -> Void

    @ViewState private var open = false

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                ForEach(Array(stack.items.prefix(3).enumerated()),
                        id: \.element.id) { index, item in
                    Image(nsImage: tray.icon(for: item))
                        .resizable()
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(Double(index - 1) * 9))
                        .offset(x: CGFloat(index - 1) * 3.5)
                }
            }
            .frame(width: 20, height: 13)
            Text("\(tray.stackName(stack)) · \(stack.items.count)")
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(stack.items.allSatisfy(\.missing)
                    ? AnyShapeStyle(style.chipFaint)
                    : AnyShapeStyle(style.chipFill),
                    in: Capsule())
        .foregroundStyle(stack.items.allSatisfy(\.missing)
                         ? style.faintColor : style.subColor)
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                dissolve()
            } else {
                open = true
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            grid
        }
    }

    /// The opened stack: every member as a tile, each one its own
    /// drag source with member verbs — pull one out and the stack
    /// thins; the last one out leaves a loose chip.
    private var grid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tray.stackName(stack))
                .font(.system(size: 11, weight: .medium))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56),
                                         spacing: 6)],
                      spacing: 6) {
                ForEach(stack.items) { item in
                    VStack(spacing: 3) {
                        Image(nsImage: tray.icon(for: item))
                            .resizable()
                            .frame(width: 24, height: 24)
                        Text(item.name)
                            .font(.system(size: 8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(4)
                    .background(style.chipFill,
                                in: RoundedRectangle(cornerRadius: 6,
                                                     style: .continuous))
                    .opacity(item.missing ? 0.38 : 1)
                    .onDrag {
                        NSItemProvider(object: item.url as NSURL)
                    }
                    .onTapGesture(count: 2) {
                        if !item.missing {
                            tray.quickLook(.item(item))
                        }
                    }
                    .contextMenu {
                        if !item.missing {
                            Button("Quick Look") {
                                tray.quickLook(.item(item))
                            }
                            Button("Reveal in Finder") {
                                tray.reveal(.item(item))
                            }
                        }
                        Button("Remove from Stack", role: .destructive) {
                            tray.removeItem(item, from: stack.id)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 280)
    }
}

/// The card's timer strip: live countdown chips, drawn only while at
/// least one exists — the add menu lives in the pinned header so an
/// empty strip is no strip at all. Timers persist across sleep/restart
/// on absolute deadlines; an overdue one shows "Done" once — the
/// notification fires through the model's `onFire`, not here.
private struct ShelfTimersRow: View {
    let timers: ShelfTimerModel
    let style: NotchCardStyle

    var body: some View {
        HStack(spacing: 4) {
            ForEach(timers.entries) { entry in
                timerChip(entry)
            }
        }
    }

    /// The chip reads `deadline.timeIntervalSinceNow` — nothing in the
    /// model mutates per second, so without a TimelineView the count
    /// only re-renders when the card redraws for other reasons. The
    /// periodic schedule ticks the text every second while mounted and
    /// costs nothing once the row unmounts. A click pauses or resumes a
    /// running timer; a done one offers +1 and +5 minutes, the snooze
    /// every timer has.
    private func timerChip(_ entry: ShelfTimerModel.Entry) -> some View {
        TimelineView(.periodic(from: .now, by: entry.paused ? 60 : 1)) { _ in
            let overdue = entry.overdue
            HStack(spacing: 3) {
                HStack(spacing: 3) {
                    Image(systemName: overdue ? "checkmark" : (entry.paused ? "pause.fill" : "timer"))
                        .font(.system(size: 9))
                    Text(overdue ? "Done" : remainingText(entry))
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !overdue else { return }
                    if entry.paused { timers.resume(entry) } else { timers.pause(entry) }
                }
                if overdue {
                    ForEach(ShelfTimerModel.extensions, id: \.self) { seconds in
                        Button("+\(Int(seconds / 60))") { timers.extend(entry, by: seconds) }
                            .buttonStyle(.plain)
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .help("Run it again for \(Int(seconds / 60)) min")
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(style.chipFill, in: Capsule())
            .foregroundStyle(overdue || entry.paused
                ? AnyShapeStyle(style.subColor)
                : AnyShapeStyle(style == .island
                                ? Color.white.opacity(0.8)
                                : Color.primary.opacity(0.75)))
            .contextMenu {
                if !overdue {
                    Button(entry.paused ? "Resume" : "Pause") {
                        if entry.paused { timers.resume(entry) } else { timers.pause(entry) }
                    }
                }
                ForEach(ShelfTimerModel.extensions, id: \.self) { seconds in
                    Button("Add \(Int(seconds / 60)) min") { timers.extend(entry, by: seconds) }
                }
                Divider()
                Button("Remove", role: .destructive) { timers.remove(entry) }
            }
            .help(help(for: entry, overdue: overdue))
        }
    }

    private func help(for entry: ShelfTimerModel.Entry, overdue: Bool) -> String {
        if overdue { return "\(entry.label) — done." }
        if entry.paused { return "\(entry.label) — paused. Click to resume." }
        let watch = entry.watchSession != nil ? " Only speaks if the session is still working." : ""
        return "\(entry.label) — due \(entry.deadline.formatted(date: .omitted, time: .shortened)). Click to pause.\(watch)"
    }

    /// `m:ss` or `h:mm:ss` remaining — the chip counts down from the
    /// absolute deadline, so a clock change shows up here too.
    private func remainingText(_ entry: ShelfTimerModel.Entry) -> String {
        let seconds = Int(entry.remaining.rounded(.up))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

/// The card's calendar glance: the next few timed events, soonest
/// first — the first carries Join when it has an http(s) link, the rest
/// whisper under it. No access or the switch off, no row: the ask lives
/// in Setup and the Notch settings, never here.
private struct ShelfCalendarRow: View {
    let calendar: ShelfCalendarModel
    let style: NotchCardStyle

    var body: some View {
        switch calendar.state {
        case .hidden, .needsPermission:
            EmptyView()
        case .idle:
            Label("Nothing in the next 24 hours", systemImage: "calendar")
                .font(.system(size: 10))
                .foregroundStyle(style.faintColor)
        case .events(let events):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                    eventLine(event, lead: index == 0)
                }
            }
        }
    }

    private func eventLine(_ event: ShelfCalendarModel.Event, lead: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 9))
                .foregroundStyle(style.subColor)
                .frame(width: 14)
                .opacity(lead ? 1 : 0)
            Text(event.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(lead ? style.subColor : style.faintColor)
            Text(event.title)
                .font(.system(size: 10))
                .foregroundStyle(lead ? style.titleColor : style.faintColor)
                .lineLimit(1)
            if lead, event.url != nil {
                Button("Join") { calendar.join(event) }
                    .controlSize(.mini)
            }
        }
        .contextMenu {
            if event.url != nil {
                Button("Join") { calendar.join(event) }
            }
            Button("Open in Calendar") { calendar.openInCalendar(event) }
        }
    }
}

/// The card's reminders rows: a check-off circle, the title, the due
/// time — overdue reads "Overdue", dueless rows carry no time. Drawn
/// only while the state has something to say; asking for access is
/// Setup's and the Notch settings' job, never a button here.
private struct ShelfRemindersRow: View {
    let reminders: ShelfRemindersModel
    let style: NotchCardStyle
    @ViewState private var adding = false
    @ViewState private var draft = ""

    var body: some View {
        switch reminders.state {
        case .hidden, .needsPermission:
            EmptyView()
        case .idle:
            HStack(spacing: 6) {
                Label("No reminders due", systemImage: "checklist")
                    .font(.system(size: 10))
                    .foregroundStyle(style.faintColor)
                Spacer(minLength: 4)
                addButton
            }
        case .items(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.prefix(ShelfRemindersModel.rowLimit)) { entry in
                    row(entry)
                }
                HStack(spacing: 6) {
                    if items.count > ShelfRemindersModel.rowLimit {
                        Text("+\(items.count - ShelfRemindersModel.rowLimit) more")
                            .font(.system(size: 9))
                            .foregroundStyle(style.faintColor)
                            .padding(.leading, 20)
                    }
                    Spacer(minLength: 4)
                    addButton
                }
            }
        }
    }

    /// Quick add: one typed line, its date read out of the words ("Call
    /// Sam tomorrow at 3pm"), saved to the default Reminders list. The
    /// field lives in a popover — the card's panel never takes keys.
    private var addButton: some View {
        Button { adding = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(style.faintColor)
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add a reminder")
        .accessibilityLabel("Add a reminder")
        .popover(isPresented: $adding, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("New reminder")
                    .font(.system(size: 11, weight: .semibold))
                TextField("Call Sam tomorrow at 3pm", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit(save)
                Text(Self.preview(draft))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack {
                    Spacer()
                    Button("Add", action: save)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.small)
                        .disabled(ShelfRemindersModel.quickAdd(draft) == nil)
                }
            }
            .padding(10)
            .frame(width: 230)
        }
    }

    private func save() {
        guard reminders.add(draft) else { return }
        draft = ""
        adding = false
    }

    /// What the line will save as: "Call Sam · Tomorrow, 15:00".
    static func preview(_ draft: String) -> String {
        guard let parsed = ShelfRemindersModel.quickAdd(draft) else { return "Type what, and when" }
        guard let due = parsed.due, let date = Calendar.current.date(from: due) else {
            return "\(parsed.title) · no date"
        }
        return "\(parsed.title) · \(ShelfRemindersModel.whenText(date, hasTime: due.hour != nil))"
    }

    private func row(_ entry: ShelfRemindersModel.Entry) -> some View {
        HStack(spacing: 6) {
            Button {
                reminders.complete(entry)
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 10))
                    .foregroundStyle(style.subColor)
            }
            .buttonStyle(.plain)
            .help("Mark done")
            Text(entry.title)
                .font(.system(size: 10))
                .foregroundStyle(style.titleColor)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let due = entry.due {
                Text(due < Date() ? "Overdue"
                    : due.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(due < Date() ? Color.orange : style.faintColor)
            }
        }
        .contextMenu {
            Button("Open in Reminders") { reminders.openInReminders(entry) }
        }
    }
}

/// The card's mirror row: the camera's own feed while the lens is
/// live, or the honest reason it isn't. `off` renders nothing — the
/// row is the feature's whole surface.
private struct ShelfMirrorRow: View {
    let mirror: ShelfMirrorModel
    let style: NotchCardStyle

    var body: some View {
        switch mirror.state {
        case .off:
            EmptyView()
        case .live:
            MirrorPreview(view: mirror.preview)
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Camera mirror")
        case .denied:
            HStack(spacing: 6) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(style.faintColor)
                Text("Camera access is off")
                    .font(.system(size: 10))
                    .foregroundStyle(style.faintColor)
                Spacer(minLength: 4)
                Button("Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.mini)
            }
        case .unavailable:
            Label("No camera", systemImage: "camera.fill")
                .font(.system(size: 10))
                .foregroundStyle(style.faintColor)
        }
    }
}

/// One verb on an ask — Approve, Deny, Open — as a small capsule the
/// card rows and the island's ask face share. The prominent one is the
/// white fill (the island's own colour for "yes"), the rest sit on the
/// chip fill; a verb whose answer is in flight dims and takes no second
/// click.
struct NotchVerbButton: View {
    let title: String
    let style: NotchCardStyle
    var prominent = false
    var busy = false
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 8.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10, weight: prominent ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(prominent
                             ? AnyShapeStyle(style == .island ? Color.black : Color.white)
                             : AnyShapeStyle(style.titleColor.opacity(0.9)))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(prominent
                          ? AnyShapeStyle(style == .island ? Color.white.opacity(0.92) : Color.accentColor)
                          : AnyShapeStyle(style.chipFill)))
            .contentShape(Capsule())
            .opacity(busy ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(title)
    }
}

/// The `MirrorPreviewView` in the SwiftUI tree — the session's layer
/// is already on the view, so updates are a no-op.
private struct MirrorPreview: NSViewRepresentable {
    let view: MirrorPreviewView

    func makeNSView(context: Context) -> MirrorPreviewView { view }
    func updateNSView(_ nsView: MirrorPreviewView, context: Context) {}
}
