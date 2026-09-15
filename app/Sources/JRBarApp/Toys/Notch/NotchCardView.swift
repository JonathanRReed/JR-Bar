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
            if pinned {
                utility.start()
                tray.revalidate()
            } else {
                utility.stop()
                calendar.stop()
            }
        }
    }
    /// The live sessions under the focus header — the island's rows
    /// minus the session the header already names.
    var rows: [NotchIslandRow] = []
    /// The headline quota meters (`NotchIsland.meters`); empty while
    /// the toy's `showUsage` is off.
    var meters: [NotchIslandMeter] = []
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
    var onOpenSession: (() -> Void)?
    var onClose: (() -> Void)?
    /// The roster affordance — the Overview window.
    var onOpenOverview: (() -> Void)?

    init(timers: ShelfTimerModel, tray: ShelfTrayModel) {
        self.timers = timers
        self.tray = tray
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

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            focusHeader(pinned: true)
            if !model.rows.isEmpty {
                ForEach(model.rows.prefix(NotchIsland.rowLimit), id: \.id) { row in
                    sessionRow(row)
                }
                if model.rows.count > NotchIsland.rowLimit {
                    Text("+\(model.rows.count - NotchIsland.rowLimit) more")
                        .font(.system(size: 10))
                        .foregroundStyle(style.faintColor)
                        .padding(.leading, 24)
                }
            }
            ShelfMediaRow(utility: model.utility, style: style)
            ShelfBatteryRow(power: model.utility.power, style: style)
            ShelfTrayRow(tray: model.tray, style: style)
            if !model.timers.entries.isEmpty {
                ShelfTimersRow(timers: model.timers, style: style)
            }
            ShelfCalendarRow(calendar: model.calendar, style: style)
            if !model.meters.isEmpty {
                ForEach(model.meters, id: \.id) { meter in
                    meterRow(meter)
                }
            }
            overviewButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPad)
        .frame(width: width)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            ShelfTrayDrop.urls(from: providers) { urls in
                model.tray.add(urls)
            }
            return true
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
    /// and the same activity word the island would say.
    private func sessionRow(_ row: NotchIslandRow) -> some View {
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
            Text(row.activity.word)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(row.activity.wordColor)
        }
        .accessibilityElement(children: .combine)
    }

    /// One quota meter: provider, window, a short bar, the percent.
    private func meterRow(_ meter: NotchIslandMeter) -> some View {
        HStack(spacing: 6) {
            Text(ProviderStyle.style(for: meter.provider).name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(style.subColor)
                .lineLimit(1)
            Text(meter.window)
                .font(.system(size: 9))
                .foregroundStyle(style.faintColor)
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
                Text("⌘O")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(style.faintColor)
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
                Spacer(minLength: 4)
                transportButton("backward.fill") { utility.send(.previousTrack) }
                transportButton(media.playing ? "pause.fill" : "play.fill") {
                    utility.send(.togglePlayPause)
                }
                transportButton("forward.fill") { utility.send(.nextTrack) }
            }
            .accessibilityElement(children: .combine)
        }
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

/// The card's battery row: the internal battery's observed state,
/// hidden entirely on machines without one — never an invented charge.
/// Volume/brightness controls are intentionally not here: macOS owns
/// those HUDs.
private struct ShelfBatteryRow: View {
    let power: AlcovePowerState
    let style: NotchCardStyle

    var body: some View {
        if power.hasBattery {
            HStack(spacing: 6) {
                Image(systemName: power.charging ? "battery.100.bolt" : "battery.50")
                    .font(.system(size: 10))
                    .foregroundStyle(style.subColor)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(style.subColor)
                    .lineLimit(1)
            }
        }
    }

    private var label: String {
        var parts: [String] = []
        if let percent = power.percent { parts.append("\(percent)%") }
        if power.fullyCharged {
            parts.append("Charged")
        } else if power.charging {
            parts.append("Charging")
        } else {
            parts.append(power.onAC ? "On AC" : "On battery")
        }
        return parts.isEmpty ? "Battery" : parts.joined(separator: " · ")
    }
}

/// The card's tray strip: dropped files as chips. A moved or deleted
/// file renders dimmed and disabled — the strip says missing, it
/// doesn't silently forget. Reveal/share only ever act on a file that
/// re-resolved this pass.
private struct ShelfTrayRow: View {
    let tray: ShelfTrayModel
    let style: NotchCardStyle

    var body: some View {
        if !tray.entries.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tray.entries) { entry in
                        trayChip(entry)
                    }
                }
            }
            .frame(maxWidth: 280)
        }
    }

    private func trayChip(_ entry: ShelfTrayModel.Entry) -> some View {
        HStack(spacing: 3) {
            Image(systemName: entry.missing ? "doc.questionmark" : "doc")
                .font(.system(size: 9))
            Text(entry.missing ? "\(entry.name) (moved)" : entry.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(entry.missing
                    ? AnyShapeStyle(style.chipFaint)
                    : AnyShapeStyle(style.chipFill),
                    in: Capsule())
        .foregroundStyle(entry.missing ? style.faintColor : style.subColor)
        .contextMenu {
            if !entry.missing {
                Button("Reveal in Finder") { tray.reveal(entry) }
                shareMenu(for: entry)
            }
            Button("Remove from Tray", role: .destructive) { tray.remove(entry) }
        }
        .onDrag {
            tray.provider(for: entry) ?? NSItemProvider()
        }
        .help(entry.missing
              ? "Missing — the file moved or was deleted."
              : entry.path)
    }

    /// Native share targets for the file; a canceled sheet delivers
    /// nothing and claims nothing.
    private func shareMenu(for entry: ShelfTrayModel.Entry) -> some View {
        Menu("Share…") {
            ForEach(tray.sharingServices(for: entry), id: \.title) { service in
                Button(service.title) {
                    service.perform(withItems: [entry.url])
                }
            }
        }
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

    private func timerChip(_ entry: ShelfTimerModel.Entry) -> some View {
        let overdue = entry.overdue
        return HStack(spacing: 3) {
            Image(systemName: overdue ? "checkmark" : "timer")
                .font(.system(size: 9))
            Text(overdue ? "Done" : remainingText(entry))
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(style.chipFill, in: Capsule())
        .foregroundStyle(overdue
            ? AnyShapeStyle(style.subColor)
            : AnyShapeStyle(style == .island
                            ? Color.white.opacity(0.8)
                            : Color.primary.opacity(0.75)))
        .contextMenu {
            Button("Remove", role: .destructive) { timers.remove(entry) }
        }
        .help(overdue ? "\(entry.label) — done." : "\(entry.label) — due \(entry.deadline.formatted(date: .omitted, time: .shortened))")
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

/// The card's calendar glance: the next event, hidden until the owner
/// grants EventKit access — no permission, no row. Join only ever
/// opens an http(s) link.
private struct ShelfCalendarRow: View {
    let calendar: ShelfCalendarModel
    let style: NotchCardStyle

    var body: some View {
        switch calendar.state {
        case .hidden:
            EmptyView()
        case .needsPermission:
            Button {
                calendar.authorizeAndLoad()
            } label: {
                Label("Show calendar", systemImage: "calendar")
                    .font(.system(size: 10))
                    .foregroundStyle(style.faintColor)
            }
            .buttonStyle(.plain)
        case .idle:
            Label("Nothing on the calendar today", systemImage: "calendar")
                .font(.system(size: 10))
                .foregroundStyle(style.faintColor)
        case .event(let event):
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 9))
                    .foregroundStyle(style.subColor)
                    .frame(width: 14)
                Text(event.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(style.subColor)
                Text(event.title)
                    .font(.system(size: 10))
                    .foregroundStyle(style.titleColor)
                    .lineLimit(1)
                if event.url != nil {
                    Button("Join") { calendar.join(event) }
                        .controlSize(.mini)
                }
            }
            .contextMenu {
                Button("Open in Calendar") { calendar.openInCalendar(event) }
            }
        }
    }
}
