import AppKit
import JRBarCore
import Observation
import SwiftUI

/// The widgets' live data (P4). The clock face is a `TimelineView`
/// and needs no model; the battery tile reads `power`, polled every
/// `interval` seconds through `AlcovePowerMonitor.read` — the same
/// `IOPSCopyPowerSourcesInfo` slice the notch's power notices use.
/// `DockModel` starts the poll only while the battery tile can draw.
@MainActor
@Observable
final class DockWidgetModel {
    private(set) var power = AlcovePowerState(hasBattery: false, onAC: false,
                                              charging: false, percent: nil,
                                              fullyCharged: false)
    private(set) var running = false

    /// The power-source read — injectable so tests can feed states.
    var read: @MainActor () -> AlcovePowerState = { AlcovePowerMonitor.read() }

    /// The battery's poll cadence — charge state drifts slowly; thirty
    /// seconds is fresh without being a metronome.
    static let interval: TimeInterval = 30

    @ObservationIgnored private var timer: Timer?

    func start() {
        guard !running else { return }
        running = true
        poll()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    private func poll() { power = read() }

    isolated deinit { timer?.invalidate() }
}

/// A widget tile: fixed `size`, real content only. The clock is an
/// analog face drawn from the current date; the battery is the
/// internal battery's charge glyph and percent — or an honest "no
/// battery" mark on a desktop. Magnification is the caller's
/// `scaleEffect`; the tile itself always lays out at rest size.
struct DockWidgetTile: View {
    let kind: DockWidgetKind
    let widgetModel: DockWidgetModel
    let size: CGFloat

    var body: some View {
        Group {
            switch kind {
            case .clock:
                ClockTile(size: size)
            case .battery:
                BatteryTile(power: widgetModel.power, size: size)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
    }

    /// The battery glyph for a reading — SF Symbols' quartile levels;
    /// the bolt rides as an overlay in the tile, not in the name, so
    /// the level stays legible. Pure — the tests pin the mapping.
    static func batterySymbol(for power: AlcovePowerState) -> String {
        guard power.hasBattery, let percent = power.percent else {
            return "battery.0percent"
        }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// The clock widget: an analog face on a `TimelineView` heartbeat —
/// a real clock, redrawn once a second for the sweep hand.
private struct ClockTile: View {
    let size: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Canvas { graphics, size in
                draw(context.date, into: &graphics,
                     rect: CGRect(origin: .zero, size: size))
            }
        }
        .help(Date.now.formatted(date: .abbreviated, time: .shortened))
    }

    /// Face, hour/minute hands, and a thin second hand — all from
    /// `date`, so the tile shows real time and nothing else.
    private func draw(_ date: Date, into graphics: inout GraphicsContext,
                      rect: CGRect) {
        let inset = rect.width * 0.06
        let face = rect.insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = face.width / 2

        graphics.stroke(Circle().path(in: face), with: .color(Color.primary.opacity(0.5)),
                        lineWidth: max(1, radius * 0.07))

        // Hour ticks at the cardinals — small and quiet.
        for tick in stride(from: 0.0, to: 360.0, by: 90.0) {
            var tickPath = Path()
            tickPath.move(to: CGPoint(x: 0, y: -radius * 0.86))
            tickPath.addLine(to: CGPoint(x: 0, y: -radius * 0.7))
            graphics.stroke(
                tickPath.applying(CGAffineTransform(rotationAngle: tick * .pi / 180)
                    .concatenating(CGAffineTransform(translationX: center.x, y: center.y))),
                with: .color(Color.primary.opacity(0.35)), lineWidth: max(0.5, radius * 0.05))
        }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date) % 12
        let minute = calendar.component(.minute, from: date)
        let second = calendar.component(.second, from: date)
        let hourAngle = (Double(hour) + Double(minute) / 60) / 12 * 360
        let minuteAngle = (Double(minute) + Double(second) / 60) / 60 * 360
        let secondAngle = Double(second) / 60 * 360

        hand(&graphics, center: center, angle: hourAngle,
             length: radius * 0.5, width: max(1.2, radius * 0.13),
             color: Color.primary.opacity(0.85))
        hand(&graphics, center: center, angle: minuteAngle,
             length: radius * 0.74, width: max(1, radius * 0.09),
             color: Color.primary.opacity(0.85))
        hand(&graphics, center: center, angle: secondAngle,
             length: radius * 0.8, width: max(0.5, radius * 0.04),
             color: Color.red.opacity(0.85))

        graphics.fill(Circle().path(in: CGRect(
            x: center.x - radius * 0.07, y: center.y - radius * 0.07,
            width: radius * 0.14, height: radius * 0.14)),
            with: .color(Color.primary.opacity(0.9)))
    }

    private func hand(_ graphics: inout GraphicsContext, center: CGPoint,
                      angle: Double, length: CGFloat, width: CGFloat,
                      color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: length * 0.12))   // small counterweight
        path.addLine(to: CGPoint(x: 0, y: -length))
        graphics.stroke(
            path.applying(CGAffineTransform(rotationAngle: angle * .pi / 180)
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))),
            with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

/// The battery widget: charge glyph, percent, a bolt while charging,
/// or a dimmed no-battery mark on machines without one.
private struct BatteryTile: View {
    let power: AlcovePowerState
    let size: CGFloat

    var body: some View {
        VStack(spacing: max(1, size * 0.04)) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: DockWidgetTile.batterySymbol(for: power))
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(power.hasBattery ? Color.primary : Color.secondary.opacity(0.5))
                if power.charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: size * 0.18))
                        .foregroundStyle(.yellow)
                        .offset(x: size * 0.05, y: -size * 0.05)
                }
            }
            Text(label)
                .font(.system(size: max(8, size * 0.2), weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(help)
    }

    private var label: String {
        guard power.hasBattery else { return "No batt" }
        return power.percent.map { "\($0)%" } ?? "—"
    }

    private var help: String {
        guard power.hasBattery else { return "No internal battery" }
        let state = power.fullyCharged ? "Fully charged"
            : power.charging ? "Charging"
            : power.onAC ? "On AC power" : "On battery"
        return "\(state)\(power.percentText)"
    }
}
