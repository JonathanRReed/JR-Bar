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
            if !pinned {
                mirrorSummoned = false
                // The rows that had a drag over them are gone with the
                // card; a stale entry would read as a drag still here.
                dropHover.removeAll()
                // Only a real fold starts the next open on Now — a
                // repeat "not pinned" while the card is already away
                // must not undo a shelf summon waiting to grow.
                if oldValue { page = .now }
            }
            refreshPrivacy()
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
        if summoned { show(.shelf) }
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
    let utility: ShelfUtilityModel
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

    /// The card's two pages: what needs the person now (sessions, their
    /// quota, who is listening, media, battery) and the shelf (files,
    /// timers, the day, the Mirror, the Control Center strip) — Alcove's
    /// calm of one thing at a time instead of every row in one scroll.
    /// Every open starts on Now; a shelf summon or the Mirror lands on
    /// the shelf.
    enum Page: Equatable { case now, shelf }
    private(set) var page: Page = .now

    func show(_ page: Page) {
        if self.page != page { self.page = page }
    }

    /// A two-finger swipe across the grown card: left is the shelf,
    /// right is back to Now.
    func flipPage(toShelf: Bool) {
        show(toShelf ? .shelf : .now)
    }

    /// What waits on the shelf page, for its tab: files, running or
    /// done timers, and a fresh copy to paste.
    var shelfWaiting: Int {
        tray.items.count + timers.entries.count + (tray.pasteOffered ? 1 : 0)
    }

    /// Who has the microphone, whether a camera is rolling — read as the
    /// card opens and on every sensor edge while it is open; nil while
    /// neither is live. The ears only ever draw the dots; the names are
    /// the card's.
    var privacyLine: String?
    /// The reader: CoreAudio and CoreMediaIO on a live card, nothing
    /// on a headless one — the tests stand in a fixed answer.
    var readPrivacy: (() -> String?)?

    func refreshPrivacy() {
        guard let readPrivacy else { return }
        let line = pinned ? readPrivacy() : nil
        if line != privacyLine { privacyLine = line }
    }

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
    /// The answer desk every ask surface shares — the panel's, published
    /// as `AskAnswerDesk.shared`. nil draws no verbs: a card without an
    /// answer path only ever offers the click-to-open. Tests hand in
    /// their own.
    @ObservationIgnored var askDesk: @MainActor () -> AskAnswerDesk? = { AskAnswerDesk.shared }
    /// How long an open's refusal stays under its row; tests hold it
    /// longer than a loaded run can take.
    @ObservationIgnored var openNoteLife: TimeInterval = 4
    /// Session → why its last open did not land, drawn where the ask's
    /// refusal would be. The row stays; the person can try again.
    private(set) var openRefusals: [String: String] = [:]
    @ObservationIgnored private var openRefusalTokens: [String: UUID] = [:]
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

    /// An open that did not land says why for a few seconds; a newer
    /// line for the same session outlives an older one's expiry.
    func noteOpenRefused(_ line: String, session: String) {
        openRefusals[session] = line
        let token = UUID()
        openRefusalTokens[session] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + openNoteLife) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.openRefusalTokens[session] == token else { return }
                self.openRefusals[session] = nil
                self.openRefusalTokens[session] = nil
            }
        }
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
        tray.copyForAgent(files, attachImage: files.count == 1
                          && ShelfTrayModel.withinAttachBound(files[0]))
        onOpenRow?(session)
    }

    /// A drop anywhere on the card but a session row: into the tray,
    /// and the card turns to the shelf page to show where it landed.
    func shelve(_ urls: [URL]) {
        tray.add(urls)
        show(.shelf)
    }

    /// The card's own drop targets a drag is over right now — the
    /// catch-all ("card"), each session row ("row:<id>") and each
    /// shelf tile ("tile:<id>"). AppKit
    /// hands a drag to these as their own destinations, so the island's
    /// hosting view hears it leave the moment it crosses onto one; the
    /// toy reads this set to tell a drag that moved onto a row from one
    /// that left the island.
    @ObservationIgnored private(set) var dropHover: Set<String> = []
    /// Any change to `dropHover`.
    @ObservationIgnored var onDropHover: (() -> Void)?
    /// A drop landed on one of the card's targets.
    @ObservationIgnored var onDropLanded: (() -> Void)?

    func setDropHover(_ target: String, _ over: Bool) {
        let changed = over ? dropHover.insert(target).inserted : dropHover.remove(target) != nil
        if changed { onDropHover?() }
    }

    /// `utility` is the shared Now Playing and battery reader; the
    /// render proofs hand in one on a test feed.
    init(timers: ShelfTimerModel, tray: ShelfTrayModel,
         utility: ShelfUtilityModel? = nil, runtimeEnabled: Bool = true) {
        self.timers = timers
        self.tray = tray
        self.utility = utility ?? ShelfUtilityModel()
        self.runtimeEnabled = runtimeEnabled
        if runtimeEnabled { readPrivacy = { NotchSensorMonitor.privacyLineNow() } }
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
    /// The edge a chip or well catches the light on.
    var hairline: Color { self == .island ? .white.opacity(0.08) : .primary.opacity(0.08) }
    /// The surface's own ink as a fill — the prominent verb, a lit
    /// switch: white on the island, the label colour on glass.
    var ink: AnyShapeStyle {
        self == .island ? AnyShapeStyle(Color.white.opacity(0.94)) : AnyShapeStyle(Color.primary.opacity(0.88))
    }
    /// What reads on `ink`.
    var inverseInk: AnyShapeStyle {
        self == .island ? AnyShapeStyle(Color.black) : AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
    }
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

    /// Air between the card's runs — the header, the sessions, the
    /// meters, the media, the foot — wider than the gap inside one.
    static let runSpacing: CGFloat = 12

    private var card: some View {
        VStack(alignment: .leading, spacing: Self.runSpacing) {
            revealRow(0, focusHeader(pinned: true))
            if model.wingHint { revealRow(1, wingHintRow) }
            switch model.page {
            case .now: nowPage
            case .shelf: shelfPage
            }
            revealRow(22, pageBar)
        }
        .padding(.horizontal, style == .island ? 16 : 14)
        .padding(.vertical, verticalPad)
        .padding(.bottom, style == .island
            ? Self.islandBottomContentInset - verticalPad : 0)
        .frame(width: width)
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.plainText],
                isTargeted: dropHover("card")) { providers in
            ShelfTrayDrop.urls(from: providers) { urls in
                model.shelve(urls)
            }
            model.onDropLanded?()
            return true
        }
    }

    /// A drop target's hover, reported to the model (`dropHover`).
    private func dropHover(_ target: String) -> Binding<Bool> {
        Binding(get: { model.dropHover.contains(target) },
                set: { model.setDropHover(target, $0) })
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
                    .frame(width: 12, height: 12)
                    .notchHitArea(horizontal: 6, vertical: 6)
            }
            .buttonStyle(.plain)
            .help("Don't show this hint again")
        }
    }

    /// The smallest target a card control offers, in points.
    static let hitSide: CGFloat = 24

    /// The header row: who the bar is about — provider tile, label,
    /// word — with the light's reason underneath. Pinned adds the
    /// card's controls on the trailing edge: the timer menu, the Mirror,
    /// Open for the named session, and close — quiet round marks, Open
    /// the one word among them.
    private func focusHeader(pinned: Bool) -> some View {
        HStack(alignment: .center, spacing: 9) {
            if let style = model.focus.style {
                ProviderTile(style: style, size: pinned ? 26 : 20)
            } else {
                Image(nsImage: StatusItemController.glyph())
                    .renderingMode(.template)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.focus.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.titleColor)
                    .lineLimit(1)
                // An Open that did not land says why where the word and
                // the light's reason sit, for a few seconds.
                if let refusal = model.focus.clickSession.flatMap({ model.openRefusals[$0] }) {
                    Text(refusal)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    focusLine
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }
            .layoutPriority(-1)
            if pinned {
                Spacer(minLength: 4)
                // The deliberate-focus controls: the timer menu keeps the
                // row hidden when empty reachable, the Mirror peeks, Open
                // raises the session's terminal, ✕ lets the card go.
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
                        headerMark("timer")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    // An AppKit pop-up: its frame is its hit area, so the
                    // frame itself is the 24-point target.
                    .frame(width: Self.hitSide, height: Self.hitSide)
                    .contentShape(Rectangle())
                    .help("Add a timer")
                    .popover(isPresented: $timerEntryShown, arrowEdge: .bottom) {
                        timerEntry
                    }
                    // The Mirror is a peek on demand, never a standing
                    // row: the lens opens here (or on ⌥-click at the
                    // notch) and closes with the card.
                    if model.mirrorEnabled() {
                        Button { model.toggleMirror() } label: {
                            headerMark(model.mirrorSummoned ? "camera.fill" : "camera",
                                       lit: model.mirrorSummoned)
                                .notchHitArea(horizontal: 2, vertical: 2)
                        }
                        .help(model.mirrorSummoned ? "Close the mirror" : "Mirror — a quick look through the camera")
                        .accessibilityLabel(model.mirrorSummoned ? "Close the mirror" : "Open the mirror")
                    }
                    if model.focus.clickSession != nil {
                        // A quiet chip, not the accent: on a red-accent
                        // Mac an accent "Open" read as a warning.
                        Button { model.onOpenSession?() } label: {
                            Text("Open")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(style.titleColor)
                                .fixedSize()
                                .padding(.horizontal, 10)
                                .frame(height: 22)
                                .background(Capsule(style: .continuous).fill(style.chipFill))
                                .overlay(Capsule(style: .continuous)
                                    .strokeBorder(style.hairline, lineWidth: 0.5))
                                .notchHitArea(horizontal: 2, vertical: 2)
                        }
                        .help("Bring this session's window forward")
                    }
                    Button { model.onClose?() } label: {
                        headerMark("xmark")
                            .notchHitArea(horizontal: 2, vertical: 2)
                    }
                    .accessibilityLabel("Close pinned card")
                }
                // Plain, so each label's own shape is its hit area: the
                // marks stay 22 points, the targets reach 26 and stop
                // halfway to their neighbours.
                .buttonStyle(.plain)
            }
        }
    }

    /// The header's second line: the activity word, then why the light
    /// is what it is, quieter.
    private var focusLine: Text {
        let word = Text(model.focus.word).foregroundStyle(style.subColor)
        guard let explanation = model.focus.explanation, !explanation.isEmpty else { return word }
        let why = Text(verbatim: " · \(explanation)").foregroundStyle(style.faintColor)
        return Text("\(word)\(why)")
    }

    /// One of the header's round marks: the glyph on a faint disc, lit
    /// while what it opens is open.
    private func headerMark(_ symbol: String, lit: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(lit ? style.titleColor : style.subColor)
            .frame(width: 22, height: 22)
            .background(Circle().fill(lit ? style.chipFill : style.chipFaint))
            .contentShape(Circle())
    }

    /// The custom timer: a label and the minutes, in a popover — the
    /// card's panel never takes keys, so the field lives here.
    private var timerEntry: some View {
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

    /// Page one — what needs the person now, in the product design's
    /// order: the sessions (asks and failures sort first), their quota,
    /// who is listening, what is playing, the battery the runs ride on.
    /// Each run is its own block, so the card reads in three glances,
    /// not one list.
    @ViewBuilder
    private var nowPage: some View {
        if !model.rows.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(model.rows.prefix(NotchIsland.rowLimit).enumerated()),
                        id: \.element.id) { index, row in
                    revealRow(2 + index, sessionRow(row))
                }
                if model.rows.count > NotchIsland.rowLimit {
                    revealRow(8, Text("+\(model.rows.count - NotchIsland.rowLimit) more")
                        .font(.system(size: 10.5))
                        .foregroundStyle(style.faintColor)
                        .padding(.leading, 15))
                }
            }
        }
        if !model.meters.isEmpty || model.privacyLine != nil {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(model.meters.enumerated()), id: \.element.id) { index, meter in
                    revealRow(9 + index, meterRow(meter))
                }
                if let privacy = model.privacyLine {
                    revealRow(12, privacyRow(privacy))
                }
            }
        }
        revealRow(13, ShelfMediaRow(utility: model.utility, style: style))
        revealRow(14, ShelfBatteryRow(power: model.utility.power, working: model.workingCount,
                                      heldAwake: model.heldAwake(), style: style))
    }

    /// Page two — the shelf and the day: files, timers, the weather
    /// and calendar, reminders, the Mirror when asked for, and the
    /// Control Center strip.
    @ViewBuilder
    private var shelfPage: some View {
        revealRow(2, ShelfTrayRow(tray: model.tray, style: style,
                                  handTargets: model.handTargets,
                                  onHand: { entry, session in
                                      model.handToAgent(entry, session: session)
                                  },
                                  dropHover: { dropHover($0) },
                                  onDropLanded: { model.onDropLanded?() }))
        if !model.timers.entries.isEmpty {
            revealRow(3, ShelfTimersRow(timers: model.timers, style: style))
        }
        // The weather leads the day; on a day with nothing scheduled it
        // is the day, and the calendar's empty line goes.
        revealRow(4, ShelfWeatherRow(reading: model.utility.weather.reading, style: style))
        if !model.weatherInCalendarSlot {
            revealRow(5, ShelfCalendarRow(calendar: model.calendar, state: model.calendar.state,
                                          style: style))
        }
        revealRow(6, ShelfRemindersRow(reminders: model.reminders, state: model.reminders.state,
                                       style: style))
        revealRow(7, ShelfMirrorRow(mirror: model.mirror, style: style))
        revealRow(8, ShelfTogglesRow(toggles: model.utility.toggles, style: style))
    }

    /// The card's foot: the two pages as a small switcher — the shelf's
    /// tab says when something waits there — and, on Now, the roster.
    private var pageBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                pageTab(.now, title: "Now")
                pageTab(.shelf, title: model.shelfWaiting > 0 ? "Shelf · \(model.shelfWaiting)" : "Shelf")
            }
            .padding(2)
            .background(Capsule(style: .continuous).fill(style.chipFaint))
            Spacer(minLength: 8)
            if model.page == .now {
                Button { model.onOpenOverview?() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Agent Overview")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(style.subColor)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule(style: .continuous).fill(style.chipFaint))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Every session at a glance (⌘O)")
            }
        }
    }

    private func pageTab(_ page: NotchCardModel.Page, title: String) -> some View {
        let selected = model.page == page
        return Button { model.show(page) } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? style.titleColor : style.faintColor)
                .padding(.horizontal, 10)
                .frame(height: 18)
                .background(Capsule(style: .continuous).fill(selected ? style.chipFill : .clear))
                // The capsule draws 18 points tall; the target is 26,
                // and stops halfway to the next tab.
                .notchHitArea(horizontal: 1, vertical: 4)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(page == .now ? "Sessions, quota, media" : "Shelf, timers, calendar, reminders")
    }

    /// Who is listening: the dots' colours (green camera, orange mic)
    /// and the apps behind them — the question the dots raise, answered
    /// in words where words belong.
    private func privacyRow(_ line: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                if line.hasPrefix("Camera") { NotchDot(color: .green) }
                if line.contains("icrophone") { NotchDot(color: .orange) }
            }
            .frame(width: 13, alignment: .leading)
            Text(line)
                .font(.system(size: 11))
                .foregroundStyle(style.subColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line)
    }

    /// One live session under the header: the provider's dot, its label,
    /// and the same activity word the island would say. A click opens
    /// the session. A waiting row carries its verbs inline instead of
    /// the word — each drawn only where `AskVerbs` says the daemon can
    /// deliver it, and every one sent through the shared desk — with
    /// the question itself on a faint second line; a refused answer or
    /// open takes that line and says why, and the ask stays open.
    private func sessionRow(_ row: NotchIslandRow) -> some View {
        let desk = model.askDesk()
        let pending = desk?.isPending(row.id) ?? false
        let openRefusal = model.openRefusals[row.id]
        let refusal = openRefusal ?? desk?.note(for: row.id)?.text
        let summary = row.ask?.summary.flatMap { $0.isEmpty ? nil : $0 }
        let opens = !CoreSession.isRemoteID(row.id) && model.onOpenRow != nil
        // The ask as the desk answers it: the row's own, with its id.
        let ask = row.ask.map { ask -> CoreAsk in
            var ask = ask
            if ask.session == nil { ask.session = row.id }
            return ask
        }
        let answerable = row.activity == .waiting && !CoreSession.isRemoteID(row.id) && desk != nil
        let choosing = answerable && ask.map(AskVerbs.chooses) == true
        let answering = answerable && ask.map(AskVerbs.approves) == true
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                NotchDot(color: ProviderStyle.style(for: row.provider).accent, size: 6)
                    .frame(width: 7)
                Text(row.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(style == .island ? .white.opacity(0.9) : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if row.activity == .waiting, ask?.isDestructive == true {
                    AskRiskMark(size: 8.5)
                }
                if (choosing || answering), let ask {
                    NotchHoldRing(ask: ask, style: style)
                }
                if choosing, let ask, let desk {
                    // A held question: Deny declines it through its
                    // hook, and its options are the answer.
                    NotchVerbButton(title: "Deny", style: style, prominent: false, busy: pending) {
                        Task { await desk.answer(ask, .deny) }
                    }
                    NotchAskChoices(ask: ask, desk: desk, style: style, busy: pending)
                } else if answering, let ask, let desk {
                    NotchVerbButton(title: "Deny", style: style, prominent: false,
                                    busy: pending) {
                        Task { await desk.answer(ask, .deny) }
                    }
                    if AskVerbs.alwaysAllows(ask) {
                        NotchVerbButton(title: "Always", style: style, prominent: false, busy: pending) {
                            Task { await desk.answer(ask, .always) }
                        }
                        .help("Approve, and let the agent remember the rule it offered")
                    }
                    NotchVerbButton(title: "Approve", style: style, prominent: true,
                                    busy: pending) {
                        Task { await desk.answer(ask, .approve) }
                    }
                } else {
                    Text(row.activity.word)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(row.activity.wordColor)
                }
            }
            if let refusal {
                Text(refusal)
                    .font(.system(size: 10.5))
                    .foregroundStyle(openRefusal == nil && desk?.note(for: row.id)?.refused == false
                                     ? AnyShapeStyle(style.faintColor) : AnyShapeStyle(Color.orange))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 15)
            } else if let summary {
                NotchAskCopy.line(summary, preview: row.activity == .waiting ? ask?.previewLine : nil,
                                  destructive: ask?.isDestructive == true, style: style, size: 10)
                    .font(.system(size: 10.5))
                    .foregroundStyle(style.subColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 15)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if opens { model.onOpenRow?(row.id) }
        }
        // Drag a screenshot to the notch and let go on the agent: the
        // file's `@path` is on the pasteboard and its session comes up.
        // A row that cannot be opened here (a peer's) is the card like
        // anywhere else: the file lands in the tray instead of bouncing.
        .onDrop(of: [UTType.fileURL], isTargeted: dropHover("row:\(row.id)")) { providers in
            ShelfTrayDrop.urls(from: providers) { urls in
                if opens {
                    model.handFiles(urls, session: row.id)
                } else {
                    model.shelve(urls)
                }
            }
            model.onDropLanded?()
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
                            model.reminders.remind(about: row.label, session: row.id, provider: row.provider,
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

    /// One quota meter: provider, window, a continuous bar, the percent
    /// — with the reset countdown the ear's drain arc only hints at, and
    /// the status feed's incident mark when the vendor is having a day.
    private func meterRow(_ meter: NotchIslandMeter) -> some View {
        let accent = ProviderStyle.style(for: meter.provider).accent
        return HStack(spacing: 7) {
            Text(ProviderStyle.style(for: meter.provider).name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(style.titleColor.opacity(0.88))
                .lineLimit(1)
            Text(meter.window)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(style.subColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule(style: .continuous).fill(style.chipFaint))
            if let countdown = PanelStore.countdown(to: meter.resetsAt, now: Date()) {
                Text(countdown)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(style.faintColor)
                    .lineLimit(1)
            }
            if meter.incident {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help("The provider's status feed reports an incident")
            }
            Spacer(minLength: 4)
            NotchLevelBar(fraction: (meter.percent ?? 0) / 100, tint: accent,
                          track: style.chipFill, height: 5,
                          dimmed: meter.percent == nil, glows: style == .island)
                .frame(width: 64)
            Text(meter.percentText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(style.subColor)
                .frame(width: 34, alignment: .trailing)
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

}

/// The card's media row, the card's one hero: the artwork large and
/// lit by its own colour, the title over the artist, the transport, a
/// continuous scrubber and the volume. Drawn only while a certified
/// source reports media — `nil` media means no row, not a dead control.
private struct ShelfMediaRow: View {
    let utility: ShelfUtilityModel
    let style: NotchCardStyle

    static let artSide: CGFloat = 48

    var body: some View {
        if let media = utility.media {
            let tint = utility.artworkTint.map { Color(nsColor: $0) }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    MediaArtwork(utility: utility, style: style, side: Self.artSide)
                        .onTapGesture { utility.raisePlayer() }
                        .help(utility.sourceName.map { "Open \($0)" } ?? "")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(style.titleColor)
                            .lineLimit(1)
                        if let byline = Self.byline(media) {
                            Text(byline)
                                .font(.system(size: 11.5))
                                .foregroundStyle(style.subColor)
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            if media.playing {
                                // The bars wear the artwork's colour
                                // when it has one.
                                let bars = tint?.opacity(0.9) ?? style.subColor
                                if utility.audioTapLive {
                                    LiveEqualizer(utility: utility, color: bars)
                                } else {
                                    DecorativeBars(live: media.playing, color: bars, height: 9)
                                }
                            }
                            Text(utility.sourceName ?? "Now playing")
                                .font(.system(size: 10))
                                .foregroundStyle(style.faintColor)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    transport(media)
                }
                if let duration = media.duration, duration > 1,
                   media.elapsed != nil {
                    TimelineView(.periodic(from: .now, by: media.playing ? 0.5 : 30)) { context in
                        let shown = utility.elapsedShown(at: context.date)
                        HStack(spacing: 8) {
                            Text(Self.clock(shown))
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(style.faintColor)
                                .frame(width: 30, alignment: .leading)
                            NotchScrubber(value: shown, range: 0...duration,
                                          tint: tint ?? style.titleColor.opacity(0.85),
                                          track: style.chipFill,
                                          label: "Playback position",
                                          valueText: Self.clock(shown),
                                          onScrub: { utility.mediaScrub = $0 },
                                          onEditing: { editing in
                                              if editing { utility.beginScrub() } else { utility.commitScrub() }
                                          })
                            Text("−" + Self.clock(duration - shown))
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(style.faintColor)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
                if let synced = utility.lyrics.lyrics {
                    LyricLines(lyrics: synced, utility: utility, playing: media.playing, style: style)
                } else if utility.lyrics.offersConsent(), LyricsQuery(media: media) != nil {
                    lyricsOffer
                }
                if let volume = utility.outputVolume {
                    // Fine adjustment without the keys — the same
                    // CoreAudio path the level HUD reads.
                    HStack(spacing: 8) {
                        Image(systemName: volume <= 0 ? "speaker.slash.fill" : "speaker.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(style.faintColor)
                            .frame(width: 30, alignment: .leading)
                        NotchScrubber(value: volume, range: 0...1,
                                      tint: style.titleColor.opacity(0.7), track: style.chipFill,
                                      label: "Volume",
                                      valueText: "\(Int((volume * 100).rounded())) percent",
                                      onScrub: { utility.setVolume($0) }, onEditing: { _ in })
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(style.faintColor)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// The artist, else the album — the title's quieter second line.
    static func byline(_ media: AlcoveMedia) -> String? {
        for part in [media.artist, media.album] {
            if let part, !part.trimmingCharacters(in: .whitespaces).isEmpty { return part }
        }
        return nil
    }

    /// Previous, play or pause on a lit disc, next.
    private func transport(_ media: AlcoveMedia) -> some View {
        HStack(spacing: 2) {
            transportButton("backward.fill", size: 11, label: "Previous track") { utility.send(.previousTrack) }
            Button { utility.send(.togglePlayPause) } label: {
                Image(systemName: media.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style.titleColor)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(style.chipFill))
                    .overlay(Circle().strokeBorder(style.hairline, lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(media.playing ? "Pause" : "Play")
            transportButton("forward.fill", size: 11, label: "Next track") { utility.send(.nextTrack) }
        }
    }

    /// Lyrics stay off until asked for: while the switch is on from
    /// before but never agreed to, one quiet line offers it. A click is
    /// the yes; nothing about the track is sent before it.
    private var lyricsOffer: some View {
        Button { utility.agreeToLyrics() } label: {
            HStack(spacing: 5) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 9))
                Text("Show synced lyrics — looks the song up on LRCLIB")
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .foregroundStyle(style.faintColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sends the title, artist, album and length to lrclib.net")
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func transportButton(_ symbol: String, size: CGFloat, label: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(style.subColor)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The track's artwork, rounded and lit from beneath by its own colour
/// — a soft pool on the black, a quieter one on glass. Its own view, so
/// the image decodes when the track changes and not on every tick of
/// the row around it.
private struct MediaArtwork: View {
    let utility: ShelfUtilityModel
    let style: NotchCardStyle
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.23, style: .continuous)
        let glow = utility.artworkTint.map { Color(nsColor: $0) } ?? .clear
        Group {
            if let artwork = utility.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    shape.fill(style.chipFill)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.36, weight: .semibold))
                        .foregroundStyle(style.subColor)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(style.hairline.opacity(1.5), lineWidth: 0.5))
        .shadow(color: glow.opacity(style == .island ? 0.6 : 0.35), radius: side * 0.3, y: side * 0.1)
        .contentShape(shape)
    }
}

/// A continuous scrubber in the card's grammar — the playhead and the
/// volume: a thin track that thickens under the pointer and a fill in
/// the artwork's colour, dragged anywhere along its length. No knob,
/// no ticks; VoiceOver adjusts it in tenths.
struct NotchScrubber: View {
    let value: Double
    let range: ClosedRange<Double>
    let tint: Color
    let track: Color
    let label: String
    let valueText: String
    let onScrub: (Double) -> Void
    let onEditing: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovering = false
    @ViewState private var dragging = false

    private var span: Double { range.upperBound - range.lowerBound }
    private var fraction: Double {
        span > 0 ? min(1, max(0, (value - range.lowerBound) / span)) : 0
    }

    var body: some View {
        let thick: CGFloat = hovering || dragging ? 6 : 4
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(track)
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(thick, geo.size.width * fraction))
            }
            .frame(height: thick)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !dragging {
                        dragging = true
                        onEditing(true)
                    }
                    let x = min(max(0, drag.location.x), geo.size.width)
                    onScrub(range.lowerBound + span * Double(x / max(1, geo.size.width)))
                }
                .onEnded { _ in
                    dragging = false
                    onEditing(false)
                })
        }
        .frame(height: 14)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: thick)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            let step = span / 10
            let next = direction == .increment ? value + step : value - step
            onEditing(true)
            onScrub(min(range.upperBound, max(range.lowerBound, next)))
            onEditing(false)
        }
    }
}

/// The synced lyrics under the transport — Atoll's sweep in the card's
/// own restraint: the current line bright with a soft highlight
/// travelling through it in time, the next line faint beneath. The
/// clock runs on the display (30 fps) only while the track plays and
/// the row can be seen: its window on screen and uncovered, the row
/// scrolled into the card. Out of sight or paused the clock stops;
/// under Reduce Motion it steps at a calm rate and the sweep stands
/// still. Silent between stamps.
struct LyricLines: View {
    let lyrics: SyncedLyrics
    let utility: ShelfUtilityModel
    let playing: Bool
    let style: NotchCardStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The window's say (`WindowVisibilityReader`) and the scroll
    /// view's: either false stops the clock — a sweep nobody can see is
    /// thirty redraws a second for nothing.
    @ViewState private var windowShowing = true
    @ViewState private var scrolledIn = true

    /// The clock the row runs: the display's 30 fps while the sweep
    /// plays and can be seen, a half-second step when it cannot sweep,
    /// stopped while paused or out of sight.
    nonisolated static func clock(playing: Bool, reduceMotion: Bool,
                                  visible: Bool) -> (interval: TimeInterval, paused: Bool, sweeps: Bool) {
        let sweeps = playing && !reduceMotion && visible
        return (sweeps ? 1.0 / 30.0 : 0.5, !playing || !visible, sweeps)
    }

    var body: some View {
        let clock = Self.clock(playing: playing, reduceMotion: reduceMotion,
                               visible: windowShowing && scrolledIn)
        let live = clock.sweeps
        TimelineView(.animation(minimumInterval: clock.interval, paused: clock.paused)) { context in
            let at = utility.elapsedShown(at: context.date)
            let position = lyrics.position(at: at)
            VStack(alignment: .leading, spacing: 2) {
                if let line = lyrics.line(at: at) {
                    Text(line)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(style.subColor)
                        .overlay {
                            if live, let progress = position.progress {
                                // The sweep: the same text, brighter,
                                // revealed left to right as the line plays.
                                Text(line)
                                    .font(.system(size: 11.5, weight: .semibold))
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
                        .font(.system(size: 10.5))
                        .foregroundStyle(style.faintColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        // The window's occlusion — another Space, a full-screen app over
        // the notch, a display asleep — the reader the buddy pauses by.
        .background(WindowVisibilityReader { windowShowing = $0 })
        // The island's grown card scrolls; a row scrolled out of it is
        // out of sight too. Outside a scroll view this never fires.
        .onScrollVisibilityChange(threshold: 0.01) { scrolledIn = $0 }
        .accessibilityHidden(true)
    }
}

/// The Control Center strip — One Switch's row as card grammar: the
/// chips chosen on Settings › Shortcuts, lit while on, dimmed while
/// off, verbs that never latch. The state is read back from the system
/// after every apply — a chip only ever shows what the Mac reports, and
/// a refused write says so in a caption under the row rather than
/// silently staying lit. Past eight chips the row wraps, so every label
/// stays readable.
private struct ShelfTogglesRow: View {
    let toggles: SystemTogglesStore
    let style: NotchCardStyle

    /// Eight across, as the strip has always been; more wrap.
    private static let perRow = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let chips = toggles.strip
            let rows = stride(from: 0, to: chips.count, by: Self.perRow).map {
                Array(chips[$0..<min($0 + Self.perRow, chips.count)])
            }
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 2) {
                    ForEach(rows[index], id: \.rawValue) { toggle in
                        chip(toggle)
                    }
                    // A short last row keeps the chip width of the rows above.
                    if index > 0, rows[index].count < Self.perRow {
                        ForEach(0..<(Self.perRow - rows[index].count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
            }
            if let caption = toggles.caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(style.faintColor)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Control Center's own grammar: a round button lit in the surface's
    /// ink while the switch is on, the name under it.
    private func chip(_ toggle: SystemToggle) -> some View {
        let on = toggles.isOn[toggle] ?? false
        let busy = toggles.applying.contains(toggle)
        let title = toggles.title(for: toggle)
        return Button {
            toggles.apply(toggle)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: toggle.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? style.inverseInk : AnyShapeStyle(style.subColor))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(on ? style.ink : AnyShapeStyle(style.chipFill)))
                    .overlay(Circle().strokeBorder(style.hairline, lineWidth: 0.5))
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(on ? style.titleColor : style.faintColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .opacity(busy ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(toggles.help(for: toggle))
        .accessibilityLabel("\(title) toggle")
        .accessibilityValue(toggle.isMomentary ? "action" : (on ? "on" : "off"))
    }
}

/// The real visualizer: six bars driven by the tap's band levels,
/// breathing out from their middle like the decorative set. It reads the
/// levels itself, so the tap's ~30 Hz publish redraws the bars and
/// nothing around them; under Reduce Motion the bars stand still and
/// re-read at 2 Hz.
struct LiveEqualizer: View {
    let utility: ShelfUtilityModel
    let color: Color
    var barWidth: CGFloat = 2.2
    var height: CGFloat = 9
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
        let levels = utility.audioLevels
        return HStack(alignment: .center, spacing: 1.5) {
            ForEach(levels.indices, id: \.self) { i in
                let level = CGFloat(min(1, max(0, levels[i])))
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: barWidth, height: height * (0.25 + 0.75 * level))
            }
        }
        .frame(height: height, alignment: .center)
        .accessibilityHidden(true)
    }
}

/// The card's battery row: the internal battery's observed state,
/// hidden entirely on machines without one — never an invented charge.
/// The glyph is drawn, not picked: a continuous fill at the charge it
/// reads, green while charging, amber when low. The line is
/// agent-aware: the system's time estimate, how many runs ride on it,
/// and whether the Mac is held awake (`AlcovePower.batteryLine`) —
/// whether a long run survives unplugged is the question only this
/// card can answer.
private struct ShelfBatteryRow: View {
    let power: AlcovePowerState
    let working: Int
    let heldAwake: Bool
    let style: NotchCardStyle

    var body: some View {
        if power.hasBattery {
            let low = !power.onAC && (power.percent ?? 100) < AlcovePower.lowThreshold
            HStack(spacing: 9) {
                NotchBatteryGlyph(fraction: Double(power.percent ?? 0) / 100,
                                  tone: power.charging ? .green : (low ? .orange : nil),
                                  plugged: power.onAC, style: style)
                Text(AlcovePower.batteryLine(power, working: working, heldAwake: heldAwake))
                    .font(.system(size: 11.5))
                    .foregroundStyle(style.subColor)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A battery drawn in the card's ink: the case, its cap, and one
/// continuous fill at the charge — the charge as a level, never a row
/// of bars. `tone` colours the fill (charging, low); a bolt rides on
/// top while the Mac is plugged in.
struct NotchBatteryGlyph: View {
    let fraction: Double
    var tone: Color?
    var plugged = false
    let style: NotchCardStyle

    var body: some View {
        let clamped = min(1, max(0, fraction))
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.2, style: .continuous)
                    .strokeBorder(style.subColor.opacity(0.8), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.6, style: .continuous)
                    .fill(tone ?? style.titleColor.opacity(0.85))
                    .frame(width: max(2, 17 * clamped))
                    .padding(2)
                if plugged {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(tone == nil ? style.inverseInk : AnyShapeStyle(Color.white))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 21, height: 11)
            Capsule(style: .continuous)
                .fill(style.subColor.opacity(0.8))
                .frame(width: 1.5, height: 4)
        }
        .frame(width: 24)
        .accessibilityHidden(true)
    }
}

/// The card's weather: the Open-Meteo reading as the day's headline —
/// the sky in its own colours, the temperature large, what it is and
/// where — over a faint outlook line (today's high and low, rain in the
/// next two hours in a cool tint). Absent while the setting is off or
/// no fetch has landed; the row never invents a sky.
struct ShelfWeatherRow: View {
    let reading: NotchWeather.Reading?
    let style: NotchCardStyle

    var body: some View {
        if let reading {
            let (symbol, label) = NotchWeather.symbol(for: reading.code)
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 22))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(reading.temperatureText)
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(style.titleColor)
                        Text([label, reading.place].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(style.subColor)
                            .lineLimit(1)
                    }
                    if let outlook = reading.outlookText {
                        Text(outlook)
                            .font(.system(size: 10.5))
                            .foregroundStyle(reading.rainInMinutes != nil
                                             ? AnyShapeStyle(style == .island ? Color.cyan.opacity(0.9)
                                                                              : Color(nsColor: .systemTeal))
                                             : AnyShapeStyle(style.faintColor))
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
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
    /// Each tile is a drop target of its own; the card counts it among
    /// the targets a drag can be over (`NotchCardModel.dropHover`).
    var dropHover: ((String) -> Binding<Bool>)?
    var onDropLanded: () -> Void = {}

    /// The shelf's tiles: a thumbnail over the name, Yoink's grammar —
    /// the shelf has its own page now, so a file shows its face rather
    /// than an 11 pt glyph. One row until the shelf fills, then two,
    /// scrolling sideways.
    static let tileWidth: CGFloat = 62
    static let tileHeight: CGFloat = 54
    static let tileSpacing: CGFloat = 6
    static let tileRadius: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !tray.entries.isEmpty || tray.pasteOffered {
                let rows = ShelfTrayModel.stripRows(tiles: tray.entries.count + (tray.pasteOffered ? 1 : 0))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(Self.tileHeight),
                                                              spacing: Self.tileSpacing),
                                          count: rows),
                              spacing: Self.tileSpacing) {
                        if tray.pasteOffered { pasteChip }
                        ForEach(tray.entries) { entry in
                            trayChip(entry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * Self.tileSpacing)
            }
            if let notice = tray.evictionNotice {
                Text(notice)
                    .font(.system(size: 9.5))
                    .foregroundStyle(style.faintColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            VStack(spacing: 4) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 28)
                Text("Paste")
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(style.subColor)
            .frame(width: Self.tileWidth, height: Self.tileHeight)
            .background(RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous)
                .strokeBorder(style.faintColor.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
            .contentShape(RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous))
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
        .onDrop(of: [.fileURL], isTargeted: dropHover?("tile:\(entry.id)")) { providers in
            // No provider carrying a file means nothing to land —
            // an unconditional yes would animate acceptance anyway.
            guard providers.contains(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }) else { return false }
            onDropLanded()
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
        VStack(spacing: 4) {
            if item.missing {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 16))
                    .frame(width: 28, height: 28)
            } else {
                // The file's own face — its Quick Look thumbnail once one
                // lands, the Finder icon until then.
                Image(nsImage: tray.icon(for: item))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
            Text(item.missing ? "\(item.name) (moved)" : item.name)
                .font(.system(size: 9.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.tileWidth - 10)
        }
        .frame(width: Self.tileWidth, height: Self.tileHeight)
        .background(item.missing
                    ? AnyShapeStyle(style.chipFaint)
                    : AnyShapeStyle(style.chipFill),
                    in: RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous)
            .strokeBorder(style.hairline, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous))
        .foregroundStyle(item.missing ? style.faintColor : style.subColor)
        .onTapGesture(count: 2) {
            if !item.missing { tray.quickLook(entry) }
        }
    }

    /// The system's own share menu for the entry's files; a canceled
    /// share delivers nothing and claims nothing. A shelf whose files
    /// all moved offers nothing to share.
    @ViewBuilder
    private func shareMenu(for entry: ShelfTrayModel.ShelfEntry) -> some View {
        let urls = tray.shareableURLs(for: entry)
        if !urls.isEmpty {
            ShareLink(items: urls) { Text("Share…") }
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
        VStack(spacing: 4) {
            // The fan: the first three faces, tilted like a stack of
            // prints — the tile's own tell that it holds more than one.
            ZStack {
                ForEach(Array(stack.items.prefix(3).enumerated()),
                        id: \.element.id) { index, item in
                    Image(nsImage: tray.icon(for: item))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .rotationEffect(.degrees(Double(index - 1) * 9))
                        .offset(x: CGFloat(index - 1) * 7)
                }
            }
            .frame(width: 44, height: 28)
            Text("\(tray.stackName(stack)) · \(stack.items.count)")
                .font(.system(size: 9.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: ShelfTrayRow.tileWidth - 10)
        }
        .frame(width: ShelfTrayRow.tileWidth, height: ShelfTrayRow.tileHeight)
        .background(stack.items.allSatisfy(\.missing)
                    ? AnyShapeStyle(style.chipFaint)
                    : AnyShapeStyle(style.chipFill),
                    in: RoundedRectangle(cornerRadius: ShelfTrayRow.tileRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ShelfTrayRow.tileRadius, style: .continuous)
            .strokeBorder(style.hairline, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: ShelfTrayRow.tileRadius, style: .continuous))
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
        HStack(spacing: 6) {
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
            HStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: overdue ? "checkmark.circle.fill" : (entry.paused ? "pause.circle.fill" : "timer"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(overdue ? AnyShapeStyle(Color.green)
                                         : entry.paused ? AnyShapeStyle(style.subColor)
                                         : AnyShapeStyle(Color.orange))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(overdue ? "Done" : remainingText(entry))
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                        Text(entry.label)
                            .font(.system(size: 9))
                            .foregroundStyle(style.faintColor)
                            .lineLimit(1)
                            .frame(maxWidth: 76, alignment: .leading)
                    }
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
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(Capsule(style: .continuous).fill(style.chipFill))
                            .help("Run it again for \(Int(seconds / 60)) min")
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(style.chipFaint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(style.hairline, lineWidth: 0.5))
            .foregroundStyle(overdue || entry.paused
                ? AnyShapeStyle(style.subColor)
                : AnyShapeStyle(style.titleColor))
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
/// first, each on a thin accent rule like the day view's — the first
/// carries Join when it has an http(s) link, the rest whisper under it.
/// No access or the switch off, no row: the ask lives in Setup and the
/// Notch settings, never here. `state` is the model's, handed in so the
/// row draws exactly what it is given.
struct ShelfCalendarRow: View {
    let calendar: ShelfCalendarModel
    let state: ShelfCalendarModel.State
    let style: NotchCardStyle

    var body: some View {
        switch state {
        case .hidden, .needsPermission:
            EmptyView()
        case .idle:
            Label("Nothing in the next 24 hours", systemImage: "calendar")
                .font(.system(size: 11))
                .foregroundStyle(style.faintColor)
        case .events(let events):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                    eventLine(event, lead: index == 0)
                }
            }
        }
    }

    private func eventLine(_ event: ShelfCalendarModel.Event, lead: Bool) -> some View {
        HStack(spacing: 9) {
            Capsule(style: .continuous)
                .fill(lead ? Color.accentColor : style.faintColor)
                .frame(width: 3, height: lead ? 26 : 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: lead ? 12 : 11, weight: lead ? .semibold : .regular))
                    .foregroundStyle(lead ? style.titleColor : style.subColor)
                    .lineLimit(1)
                Text(Self.span(event))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(style.faintColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if lead, event.url != nil {
                NotchVerbButton(title: "Join", style: style, prominent: true,
                                systemImage: "video.fill") { calendar.join(event) }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if event.url != nil {
                Button("Join") { calendar.join(event) }
            }
            Button("Open in Calendar") { calendar.openInCalendar(event) }
        }
    }

    /// "10:30 – 11:00 AM", the event's own span in the person's clock.
    static func span(_ event: ShelfCalendarModel.Event) -> String {
        (event.start..<max(event.start, event.end)).formatted(date: .omitted, time: .shortened)
    }
}

/// The card's reminders rows: a check-off circle, the title, the due
/// time — overdue reads "Overdue", dueless rows carry no time. Drawn
/// only while the state has something to say; asking for access is
/// Setup's and the Notch settings' job, never a button here.
struct ShelfRemindersRow: View {
    let reminders: ShelfRemindersModel
    let state: ShelfRemindersModel.State
    let style: NotchCardStyle
    @ViewState private var adding = false
    @ViewState private var draft = ""

    var body: some View {
        switch state {
        case .hidden, .needsPermission:
            EmptyView()
        case .idle:
            HStack(spacing: 6) {
                Label("No reminders due", systemImage: "checklist")
                    .font(.system(size: 11))
                    .foregroundStyle(style.faintColor)
                Spacer(minLength: 4)
                addButton
            }
        case .items(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items.prefix(ShelfRemindersModel.rowLimit)) { entry in
                    row(entry)
                }
                HStack(spacing: 6) {
                    if items.count > ShelfRemindersModel.rowLimit {
                        Text("+\(items.count - ShelfRemindersModel.rowLimit) more")
                            .font(.system(size: 10))
                            .foregroundStyle(style.faintColor)
                            .padding(.leading, 22)
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
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(style.subColor)
                .frame(width: 20, height: 20)
                .background(Circle().fill(style.chipFaint))
                .contentShape(Circle())
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
        HStack(spacing: 9) {
            Button {
                reminders.complete(entry)
            } label: {
                Circle()
                    .strokeBorder(style.subColor, lineWidth: 1.2)
                    .frame(width: 13, height: 13)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Mark done")
            .accessibilityLabel("Mark \(entry.title) done")
            Text(entry.title)
                .font(.system(size: 11.5))
                .foregroundStyle(style.titleColor)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let due = entry.due {
                Text(due < Date() ? "Overdue"
                    : due.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
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
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style.hairline, lineWidth: 0.5))
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

/// One verb on an ask — Approve, Deny, Open — as a capsule the card
/// rows and the island's ask face share, the height of the ask's verb
/// row. The prominent one is filled in the surface's ink (white on the
/// island, the label colour on glass — never the accent, which on a red
/// Mac reads as a warning), the rest sit on the chip fill with a
/// hairline; a verb whose answer is in flight dims and takes no second
/// click.
struct NotchVerbButton: View {
    let title: String
    let style: NotchCardStyle
    var prominent = false
    var busy = false
    var systemImage: String?
    let action: () -> Void

    /// The ask face's verb row, and every row that carries verbs.
    static let height: CGFloat = 22

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: prominent ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(prominent ? style.inverseInk : AnyShapeStyle(style.titleColor.opacity(0.92)))
            .padding(.horizontal, 10)
            .frame(height: Self.height)
            .background(
                Capsule(style: .continuous)
                    .fill(prominent ? style.ink : AnyShapeStyle(style.chipFill)))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(style.hairline.opacity(prominent ? 0 : 1), lineWidth: 0.5))
            .contentShape(Capsule())
            .opacity(busy ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(title)
    }
}

/// The decide lane's hold beside a held ask's verbs: a thin ring that
/// empties while the agent's hook waits (`NotchHold`), gone the moment
/// the hold lapses. A mark, never a count. It sweeps on a once-a-second
/// tick; under Reduce Motion it steps every five seconds instead, and
/// it ticks only while a hold with a deadline is on screen: the clock
/// stops on the deadline rather than waiting for the daemon to drop it.
struct NotchHoldRing: View {
    let ask: CoreAsk
    let style: NotchCardStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if ask.isHeldForDecision, let until = ask.decision?.holdUntil {
            TimelineView(NotchHoldSchedule(until: Date(timeIntervalSince1970: until),
                                           step: reduceMotion ? 5 : 1)) { context in
                if let left = NotchHold.remaining(ask, now: context.date) {
                    ZStack {
                        Circle()
                            .stroke(style.chipFill, lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: left)
                            .stroke(style.subColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(reduceMotion ? nil : .linear(duration: 1), value: left)
                    }
                    .frame(width: 10, height: 10)
                    .help("The agent is waiting for this answer; when the ring empties it asks in its own window")
                    .accessibilityElement()
                    .accessibilityLabel("Held for your answer")
                    .accessibilityValue("\(Int((left * 100).rounded())) percent left")
                }
            }
        }
    }
}

/// The hold ring's clock (`NotchHold.ticks`): it runs to the deadline
/// and stops there.
struct NotchHoldSchedule: TimelineSchedule {
    let until: Date
    let step: TimeInterval

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> UnfoldSequence<Date, Date?> {
        NotchHold.ticks(from: startDate, until: until, every: step)
    }
}

/// An ask's words at the notch: the question, then — monospaced, after
/// a dot — what the agent wants to run, red when it is destructive. One
/// `Text`, so the ask face's measured lines still hold it; a preview
/// that does not fit is cut, never the question.
enum NotchAskCopy {
    static func line(_ summary: String, preview: String?, destructive: Bool,
                     style: NotchCardStyle = .island, size: CGFloat = 10.5) -> Text {
        guard let preview else { return Text(summary) }
        let dot = Text(verbatim: " · ").foregroundStyle(style.faintColor)
        let run = Text(preview)
            .font(.system(size: size, design: .monospaced))
            .foregroundStyle(destructive ? AnyShapeStyle(Color.red.opacity(0.9)) : AnyShapeStyle(style.subColor))
        return Text("\(Text(summary))\(dot)\(run)")
    }
}

/// A held question's options on a notch verb row: a verb each for one
/// tiny single-pick question — a click is the answer — else one menu
/// that holds them all, with Send once every question has a pick. The
/// answer goes through the shared desk and the agent's own hook.
struct NotchAskChoices: View {
    let ask: CoreAsk
    let desk: AskAnswerDesk
    let style: NotchCardStyle
    var busy = false

    private var choices: [CoreAskChoice] { ask.decision?.choices ?? [] }

    var body: some View {
        switch AskChoiceLayout.layout(choices, maxButtons: 2, maxCharacters: 18) {
        case .buttons(let labels):
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                NotchVerbButton(title: label, style: style, prominent: index == 0, busy: busy) {
                    if let choice = choices.first { desk.pick(label, in: choice, of: ask) }
                }
                .help("Answer “\(label)”")
            }
        case .menu:
            let picks = desk.picks(for: ask)
            Menu {
                AskChoiceMenuItems(choices: choices, picks: picks,
                                   pick: { desk.pick($0, in: $1, of: ask) },
                                   send: { Task { await desk.sendPicks(for: ask) } })
            } label: {
                Text(AskChoiceLayout.menuTitle(choices, picks: picks))
                    .font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tint(style.titleColor)
            .disabled(busy)
            .help(choices.count == 1 ? choices[0].question : "\(choices.count) questions — pick an answer for each")
            if picks.isComplete(choices), choices.count > 1 || choices.first?.multi == true {
                NotchVerbButton(title: "Send", style: style, prominent: true, busy: busy) {
                    Task { await desk.sendPicks(for: ask) }
                }
            }
        }
    }
}

/// The `MirrorPreviewView` in the SwiftUI tree — the session's layer
/// is already on the view, so updates are a no-op.
private struct MirrorPreview: NSViewRepresentable {
    let view: MirrorPreviewView

    func makeNSView(context: Context) -> MirrorPreviewView { view }
    func updateNSView(_ nsView: MirrorPreviewView, context: Context) {}
}

extension View {
    /// Grows a small control's hit area without moving anything: the
    /// padding is taken back, the shape stays. Keep `horizontal` within
    /// half the row's spacing so two neighbours never claim one point.
    func notchHitArea(horizontal: CGFloat = 8, vertical: CGFloat = 8) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .contentShape(Rectangle())
            .padding(.horizontal, -horizontal)
            .padding(.vertical, -vertical)
    }
}
