import AppKit
import JRBarLEDS
import SwiftUI

/// The composer's choices as the sheet holds them: plain values a
/// control can bind to, turned into a `LEDSComposition` in one place.
struct ComposeChoices: Equatable {
    enum BaseKind: String, CaseIterable, Identifiable {
        case solid, gradient
        var id: String { rawValue }
        var title: String { self == .solid ? "One colour" : "Gradient" }
    }

    enum MotionKind: String, CaseIterable, Identifiable {
        case steady, breathe, roll
        var id: String { rawValue }
        var title: String {
            switch self {
            case .steady: return "Steady"
            case .breathe: return "Breathe"
            case .roll: return "Roll"
            }
        }
    }

    var baseKind: BaseKind = .solid
    var baseFrom = "#FF9F0A"
    var baseTo = "#0A84FF"
    var motion: MotionKind = .breathe
    var periodSeconds = 2.4
    var rollLeftward = false
    var accentOn = false
    var accentColor = "#FFFFFF"
    var accentStepMs = 300.0
    var accentLeftward = false
    /// LEDs held at `heldColor` (0…7).
    var held: Set<Int> = []
    var heldColor = "#FF3B30"
    /// 0.05…1 of the firmware's full drive.
    var brightness = 1.0

    var composition: LEDSComposition {
        func color(_ hex: String) -> RGB8 { RGB8(hex: hex.uppercased()) ?? .black }
        let base: LEDSComposition.Base = baseKind == .solid
            ? .solid(color(baseFrom)) : .gradient(color(baseFrom), color(baseTo))
        let period = Int((periodSeconds * 1000).rounded())
        let motion: LEDSComposition.Motion
        switch self.motion {
        case .steady: motion = .steady
        case .breathe: motion = .breathe(periodMs: period)
        case .roll: motion = .roll(periodMs: period, leftward: rollLeftward)
        }
        let accent = accentOn
            ? LEDSComposition.Accent(color: color(accentColor), stepMs: Int(accentStepMs.rounded()), leftward: accentLeftward)
            : nil
        let overrides = Dictionary(uniqueKeysWithValues: held.map { ($0, color(heldColor)) })
        return LEDSComposition(base: base, motion: motion, accent: accent, overrides: overrides,
                               brightness: Int((min(1, max(0, brightness)) * 255).rounded()))
    }
}

/// Effect Studio › Program › Compose: a light built from layers — a base
/// and its motion, a moving accent, LEDs held at their own colour, and a
/// brightness — previewed on the strip, the Dot and the band as it is
/// built, then handed to the editor as text. The composer says what it
/// left out when layers cannot play together; nothing is written to a
/// device until the editor's own Play or Burn.
struct ComposeSheet: View {
    @Bindable var model: LEDSStudioModel
    @ViewState private var choices = ComposeChoices()

    private var composed: LEDSComposed { LEDSComposer.compose(choices.composition) }

    var body: some View {
        let composed = self.composed
        let analysis = LEDSStudioAnalysis(composed.text)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compose a light").font(.title3.weight(.semibold))
                Text("Stack a base, a moving accent and held LEDs; the composer writes the program that plays them.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Base").gridColumnAlignment(.trailing)
                    HStack(spacing: 8) {
                        Picker("Base", selection: $choices.baseKind) {
                            ForEach(ComposeChoices.BaseKind.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).fixedSize()
                        well($choices.baseFrom, label: choices.baseKind == .solid ? "Base colour" : "Gradient start")
                        if choices.baseKind == .gradient {
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            well($choices.baseTo, label: "Gradient end")
                        }
                    }
                }
                GridRow {
                    Text("Motion")
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Motion", selection: $choices.motion) {
                            ForEach(ComposeChoices.MotionKind.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).fixedSize()
                        if choices.motion != .steady {
                            HStack(spacing: 8) {
                                Slider(value: $choices.periodSeconds, in: 1...8, step: 0.1).frame(width: 180)
                                Text(String(format: "%.1f s", choices.periodSeconds)).monospacedDigit().foregroundStyle(.secondary)
                                if choices.motion == .roll { direction($choices.rollLeftward) }
                            }
                        }
                    }
                }
                GridRow {
                    Text("Accent")
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Toggle("A moving accent", isOn: $choices.accentOn)
                                .disabled(choices.motion == .breathe)
                            if choices.accentOn { well($choices.accentColor, label: "Accent colour") }
                        }
                        if choices.accentOn, choices.motion == .steady {
                            HStack(spacing: 8) {
                                Slider(value: $choices.accentStepMs, in: 150...1000, step: 10).frame(width: 180)
                                Text("\(Int(choices.accentStepMs)) ms a step").monospacedDigit().foregroundStyle(.secondary)
                                direction($choices.accentLeftward)
                            }
                        }
                    }
                }
                GridRow {
                    Text("Hold")
                    HStack(spacing: 8) {
                        ForEach(0..<LEDSComposer.ledCount, id: \.self) { index in
                            Button {
                                if choices.held.contains(index) { choices.held.remove(index) } else { choices.held.insert(index) }
                            } label: {
                                Circle()
                                    .fill(choices.held.contains(index) ? Color(nsColor: NSColor(hex: choices.heldColor) ?? .gray) : Color.primary.opacity(0.10))
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Hold LED \(index + 1)")
                            .accessibilityValue(choices.held.contains(index) ? "held" : "free")
                        }
                        well($choices.heldColor, label: "Held colour")
                    }
                    .disabled(choices.motion == .roll)
                }
                GridRow {
                    Text("Brightness")
                    HStack(spacing: 8) {
                        Slider(value: $choices.brightness, in: 0.05...1).frame(width: 180)
                        Text("\(Int((choices.brightness * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }

            HStack(alignment: .top, spacing: 18) {
                preview("SidePulse Pro") {
                    LEDStripPreview(program: analysis.compiled.program, ledCount: 8, style: .dots, dotSize: 14, spacing: 9)
                }
                preview("Dot") {
                    LEDStripPreview(program: analysis.compiled.program, ledCount: 2, style: .dots, dotSize: 14, spacing: 9)
                        .frame(width: 70)
                }
                preview("Screen Bar") {
                    LEDStripPreview(program: analysis.compiled.program, ledCount: 8, style: .band, dotSize: 7)
                        .frame(width: 150)
                }
            }

            ForEach(composed.dropped, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(composed.adjusted, id: \.self) { note in
                Label(note, systemImage: "tortoise")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 18) {
                BudgetBar(title: "Bytes", used: analysis.bytes, limit: LEDSLimits.maxProgramBytes)
                BudgetBar(title: "Lines", used: analysis.lines, limit: LEDSLimits.maxProgramLines)
            }

            HStack {
                Text(model.analysis.isBlank ? "" : "Replaces the text in the editor; the Studio program stays as it is.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", role: .cancel) { model.composing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Use in editor") {
                    model.text = composed.text
                    model.composing = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!analysis.playable)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func well(_ hex: Binding<String>, label: String) -> some View {
        ColorPicker(label, selection: Binding(
            get: { Color(nsColor: NSColor(hex: hex.wrappedValue) ?? .gray) },
            set: { if let value = NSColor($0).hexString { hex.wrappedValue = value } }
        ), supportsOpacity: false)
        .labelsHidden()
        .help(label)
    }

    private func direction(_ leftward: Binding<Bool>) -> some View {
        Picker("Direction", selection: leftward) {
            Image(systemName: "arrow.right").tag(false).accessibilityLabel("Rightward")
            Image(systemName: "arrow.left").tag(true).accessibilityLabel("Leftward")
        }
        .labelsHidden().pickerStyle(.segmented).fixedSize()
    }

    private func preview<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }
}
