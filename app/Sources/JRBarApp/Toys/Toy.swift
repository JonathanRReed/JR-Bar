import AppKit
import JRBarCore
import Observation
import SwiftUI

/// What a toy card's status chip says. Always a fact, never a promise:
/// "Needs Screen Recording", "Paused: lid closed", "Bendy is rendering
/// it", "No lid-angle sensor on this Mac".
enum ToyStatus: Equatable {
    case off
    case on
    case paused(String)
    case needsPermission(String)
    case external(String)
    case unavailable(String)
    /// Working, but a missing permission holds back part of it —
    /// "Wallpaper only".
    case limited(String)
    /// Off by its switch, with one quiet fact still true — the tank's
    /// game keeps count while its window is closed. Neutral, not a
    /// warning.
    case note(String)

    var text: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .paused(let why): return why
        case .needsPermission(let why): return why
        case .external(let what): return what
        case .unavailable(let why): return why
        case .limited(let what): return what
        case .note(let what): return what
        }
    }

    var tint: Color {
        switch self {
        case .off: return Color(nsColor: .tertiaryLabelColor)
        case .on: return .green
        case .paused, .external, .limited: return Color(nsColor: .systemOrange)
        case .needsPermission: return .red
        case .unavailable, .note: return Color(nsColor: .secondaryLabelColor)
        }
    }

    /// Whether the card draws a chip at all: plain on and off are the
    /// switch's to say, so only a state with words of its own gets one.
    var showsChip: Bool {
        switch self {
        case .on, .off: return false
        default: return true
        }
    }
}

/// The one shape every toy card renders from, so the Toys page never
/// special-cases a toy (docs/TOYS.md). Implementations are
/// `@MainActor @Observable` classes owned by `ToysStore`.
@MainActor
protocol Toy: AnyObject, Observable {
    /// "fold", "aquarium", …
    var id: String { get }
    var name: String { get }
    /// One line, Jonathan's voice.
    var blurb: String { get }
    /// An SF Symbol.
    var symbol: String { get }
    var isOn: Bool { get set }
    /// What the chip says.
    var status: ToyStatus { get }
    /// The card's disclosure body.
    @ViewBuilder var controls: AnyView { get }
    /// What the toy costs right now, measured where it can be: "Drawing
    /// 30 fps · none when covered". nil hides the line. `now` is system
    /// uptime, the clock `ToyMeter` stamps with.
    func cost(at now: TimeInterval) -> String?
    /// The titled rows inside `controls` that Settings search can land
    /// on (`ToySearchCatalog`).
    var searchRows: [ToySearchRow] { get }
}

extension Toy {
    func cost(at now: TimeInterval) -> String? { nil }
}

/// Runs `body` now, and again after every change to the observable state
/// it read, on the main actor, until `cancel()`. Outside SwiftUI: an
/// AppKit view that follows a model this way changes itself and asks
/// SwiftUI for nothing (the Fold card's lid), and a model that keeps a
/// small snapshot of a big one writes it only when it changed (the Agent
/// Overview's providers).
@MainActor
final class ObservationLoop {
    private var active = true
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
        run()
    }

    func cancel() {
        active = false
    }

    private func run() {
        guard active else { return }
        withObservationTracking {
            body()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.run() }
        }
    }
}

/// A toy's measured background work (docs/TOYS.md): every frame drawn
/// or sensor read ticks it, and the card reads the rate back over the
/// last few seconds — so a regression like an uncapped timeline shows
/// up on the card, next to the switch. Deliberately not observable: a
/// tick per frame must invalidate nothing; the card re-reads it on its
/// own slow clock, and only while it is open.
@MainActor
final class ToyMeter {
    /// The span a rate is measured over.
    static let window: TimeInterval = 3
    private var stamps: [TimeInterval]
    private var next = 0

    /// Room for 170 events a second over the window — past any rate a
    /// toy should ever run at.
    init(capacity: Int = 512) {
        stamps = Array(repeating: -.infinity, count: max(1, capacity))
    }

    static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func tick(at now: TimeInterval = ToyMeter.uptime) {
        stamps[next] = now
        next = (next + 1) % stamps.count
    }

    /// Events a second over the last `window`.
    func rate(at now: TimeInterval = ToyMeter.uptime) -> Double {
        let since = now - Self.window
        return Double(stamps.lazy.filter { $0 > since && $0 <= now }.count) / Self.window
    }

    /// "Drawing 30 fps", or nil when nothing drew in the window.
    func drawing(at now: TimeInterval) -> String? {
        let fps = rate(at: now)
        return fps < 0.5 ? nil : "Drawing \(Int(fps.rounded())) fps"
    }
}

/// One toy on the page, as its own group: a head row — the toy's mark
/// in its tint, name, status pill, blurb, the turning chevron and the
/// on/off switch — and, while open, a second row with what it costs and
/// the toy's `controls` in the shared card-body styles.
///
/// Put each card in its own `Section`: the head and the body are two
/// rows of it, so the form draws the hairline between them.
///
/// Inside the Settings window the card's disclosure is the store's
/// (`SettingsStore.expandedCards`), so a search hit can open it; the
/// card carries its scroll anchor and lights up while it is the hit.
struct ToyCard: View {
    let toy: any Toy
    let tint: Color
    @Environment(SettingsStore.self) private var settings: SettingsStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var localExpanded = false
    @ViewState private var hovering = false

    private var expanded: Bool {
        settings.map { $0.expandedCards.contains(toy.id) } ?? localExpanded
    }

    private func setExpanded(_ open: Bool) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
            if let settings { settings.setCard(toy.id, expanded: open) } else { localExpanded = open }
        }
    }

    var body: some View {
        let lit = settings?.highlightedCard == toy.id
        head
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(lit ? 0.16 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: lit)
            .id(SettingsStore.cardAnchor(toy.id))
        if expanded {
            VStack(alignment: .leading, spacing: 0) {
                ToyCostLine(toy: toy)
                toy.controls
            }
            .cardBodyStyle()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, SettingsMetrics.xs)
        }
    }

    @ViewBuilder private var head: some View {
        // Read the observable surface here so the card re-renders on any
        // change; the binding's get returns the value tracked in this
        // body, so the switch can never sit stale.
        let status = toy.status
        let isOn = toy.isOn
        let toggle = Binding(get: { isOn }, set: { toy.isOn = $0 })
        // Keep expansion and enablement as sibling controls. Nested actions
        // in a DisclosureGroup label can replace its expansion action.
        HStack(alignment: .center, spacing: SettingsMetrics.m) {
            Button { setExpanded(!expanded) } label: {
                HStack(alignment: .center, spacing: SettingsMetrics.m) {
                    SettingsIconTile(symbol: toy.symbol, tint: tint, size: SettingsMetrics.cardTile)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.s) {
                            Text(toy.name)
                                .font(.body.weight(.semibold))
                                .layoutPriority(1)
                            if status.showsChip {
                                StatusPill(status.text, tint: status.tint)
                            }
                        }
                        Text(toy.blurb)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    DisclosureChevron(open: expanded, hovering: hovering)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("\(expanded ? "Hide" : "Show") \(toy.name) settings")
            Toggle(toy.name, isOn: toggle)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, SettingsMetrics.xs)
    }
}

extension ToyCard {
    /// Each card's own hue, so a page of cards scans like System
    /// Settings' sidebar instead of one colour repeated; a card this
    /// table does not name wears the page's tint.
    static func tint(for id: String, page: Color) -> Color {
        switch id {
        case "menuBar": return Color(nsColor: .systemBlue)
        case "notch": return Color(nsColor: .systemIndigo)
        case "dock": return Color(nsColor: .systemTeal)
        case "agents": return Color(nsColor: .systemPurple)
        case "data-hoarder": return Color(nsColor: .systemBrown)
        // Keep Awake's cup in coffee-lamp yellow, the one hue no page or
        // card wears, so it never twins the Utilities header or Notch.
        case "keepAwake": return Color(nsColor: .systemYellow)
        case "fold": return Color(nsColor: .systemOrange)
        case "aquarium": return Color(nsColor: .systemCyan)
        case "notch-buddy": return Color(nsColor: .systemGreen)
        // Confetti shares the Toys page's party popper, so it takes red
        // rather than the page's magenta and never twins the header.
        case "confetti": return Color(nsColor: .systemRed)
        default: return page
        }
    }
}

/// The toy's measured cost, re-read once a second while the card is
/// open — a closed card runs no clock for it.
private struct ToyCostLine: View {
    let toy: any Toy

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let line = toy.cost(at: ToyMeter.uptime) {
                Label(line, systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.s)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                    .padding(.bottom, SettingsMetrics.xs)
                    .accessibilityLabel("Cost: \(line)")
            }
        }
    }
}
