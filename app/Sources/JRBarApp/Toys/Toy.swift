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

    var text: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .paused(let why): return why
        case .needsPermission(let why): return why
        case .external(let what): return what
        case .unavailable(let why): return why
        case .limited(let what): return what
        }
    }

    var tint: Color {
        switch self {
        case .off: return Color(nsColor: .tertiaryLabelColor)
        case .on: return .green
        case .paused, .external, .limited: return Color(nsColor: .systemOrange)
        case .needsPermission: return .red
        case .unavailable: return Color(nsColor: .secondaryLabelColor)
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
}

extension Toy {
    func cost(at now: TimeInterval) -> String? { nil }
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

/// One toy on the page: the symbol tile in the page tint, name, blurb,
/// status chip, the on/off toggle, and a disclosure with the toy's
/// `controls`.
struct ToyCard: View {
    let toy: any Toy
    let tint: Color
    @ViewState private var expanded = false

    var body: some View {
        // Read the observable surface here so the card re-renders on any
        // change; the binding's get returns the value tracked in this
        // body, so the switch can never sit stale.
        let status = toy.status
        let isOn = toy.isOn
        let toggle = Binding(get: { isOn }, set: { toy.isOn = $0 })
        // Keep expansion and enablement as sibling controls. Nested actions
        // in a DisclosureGroup label can replace its expansion action.
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                Button { expanded.toggle() } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tint.gradient)
                            Image(systemName: toy.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(toy.name)
                                .fontWeight(.medium)
                            Text(toy.blurb)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        StatusChip(status: status)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expanded ? "Hide" : "Show") \(toy.name) settings")
                Toggle(toy.name, isOn: toggle)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.vertical, 2)
            if expanded {
                ToyCostLine(toy: toy)
                    .padding(.leading, 20)
                    .padding(.top, 2)
                toy.controls
                    .padding(.leading, 20)
                    .padding(.top, 2)
            }
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
                    .accessibilityLabel("Cost: \(line)")
            }
        }
    }
}

/// The card's status chip. On the live "On" state the capsule breathes —
/// a slow opacity pulse on a timeline that pauses for every other state
/// and under Reduce Motion — and long status text truncates instead of
/// pushing the toggle out.
private struct StatusChip: View {
    let status: ToyStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var live: Bool { status == .on && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !live)) { context in
            let breath = live
                ? (1 - cos(context.date.timeIntervalSinceReferenceDate * .pi * 2 / 2.6)) / 2
                : 0
            Text(status.text)
                .font(.caption)
                .foregroundStyle(status.tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(status.tint.opacity(0.14 + 0.10 * breath), in: Capsule())
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The page header's mark: "JR" set tight in the page tint's rounded
/// square, drawn in SwiftUI — no asset.
struct JRMonogram: View {
    var tint: Color = Color(red: 0.93, green: 0.30, blue: 0.62)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.gradient)
            Text("JR")
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .tracking(-1)
                .foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
    }
}
