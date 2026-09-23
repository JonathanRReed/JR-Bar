import JRBarCore
import SwiftUI

/// One moment the lights could meet: an event, whose it is, the scene in
/// force, and the surface it plays on — the inputs of the daemon's
/// `EffectAssignmentContext`.
struct EffectSituation: Equatable {
    var semantic: EffectSemantic = .completion
    var scene: String = EffectScene.calm.rawValue
    var provider: String?
    /// `provider:instance`, the daemon's wire form.
    var instance: String?
    /// A session's origin label ("Claude in VS Code").
    var project: String?
    /// A strip or Dot id; nil for the Screen Bar, which never resolves
    /// device-scope rows.
    var device: String?
}

/// Which assignment wins a situation — the daemon's
/// `resolve_effect_assignment`, mirrored so the Studio can answer "why is
/// Codex purple in Night" before it happens. An urgent event (an ask, a
/// failure) looks at the state scope alone, where its reserved alert can
/// never be replaced; anything else walks the scopes most specific first
/// and the first row that names this situation wins, even when its effect
/// is no longer installed (the daemon then plays the default rather than
/// looking further). The rows it passed over are returned too: they are
/// the assignments this one shadows.
enum EffectSituationResolver {
    struct Outcome: Equatable {
        /// The row that decides, nil when none names this situation.
        let winner: EffectAssignment?
        /// True for asks and failures: the reserved alert plays.
        let reserved: Bool
        /// Rows that also name the situation, shadowed by the winner.
        let shadowed: [EffectAssignment]
    }

    static func target(of situation: EffectSituation, for scope: EffectScope) -> String? {
        switch scope {
        case .global: return nil
        case .semantic: return situation.semantic.rawValue
        case .provider: return situation.provider
        case .providerInstance: return situation.instance
        case .project: return situation.project
        case .device: return situation.device
        case .scene: return situation.scene
        }
    }

    static func resolve(_ situation: EffectSituation, in document: EffectAssignmentDocument?) -> Outcome {
        guard !situation.semantic.isUrgent else {
            return Outcome(winner: nil, reserved: true, shadowed: [])
        }
        var matches: [EffectAssignment] = []
        for scope in EffectScope.precedence {
            let target = target(of: situation, for: scope)
            if scope != .global, target == nil { continue }
            if let row = document?.assignment(scope: scope, targetID: target) { matches.append(row) }
        }
        return Outcome(winner: matches.first, reserved: false, shadowed: Array(matches.dropFirst()))
    }
}

/// Effect Studio › assignments › "Try a situation": pick an event, a
/// provider, a scene and a surface, and see which assignment wins — the
/// deciding scope named — and which rows it shadows.
struct EffectSituationPanel: View {
    @Bindable var store: EffectStudioStore
    @ViewState private var situation = EffectSituation()
    @ViewState private var surface = "screen-bar"
    @ViewState private var seeded = false

    private static let events: [EffectSemantic] = [.completion, .notification, .asking, .failure]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try a situation").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                GridRow {
                    picker("Event", selection: $situation.semantic) {
                        ForEach(Self.events) { Text($0.label).tag($0) }
                    }
                    picker("Scene", selection: $situation.scene) {
                        ForEach(EffectScene.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }
                GridRow {
                    picker("Provider", selection: Binding(get: { situation.provider ?? "" },
                                                          set: { situation.provider = $0.isEmpty ? nil : $0 })) {
                        Text("Any").tag("")
                        ForEach(store.providerTargets, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    picker("Where", selection: $surface) {
                        Text("Screen Bar").tag("screen-bar")
                        ForEach(store.deviceTargets, id: \.id) { Text($0.label).tag($0.id) }
                    }
                }
                if !store.projectTargets.isEmpty {
                    GridRow {
                        picker("Project", selection: Binding(get: { situation.project ?? "" },
                                                             set: { situation.project = $0.isEmpty ? nil : $0 })) {
                            Text("None").tag("")
                            ForEach(store.projectTargets, id: \.id) { Text($0.label).tag($0.id) }
                        }
                        .gridCellColumns(2)
                    }
                }
            }
            outcome
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            situation.scene = store.activeScene
            situation.provider = store.providerTargets.first(where: \.live)?.id
        }
    }

    /// The Dot follows the strip while linked: its own device rows are
    /// shadowed, so it resolves as the strip does.
    private var resolvedSituation: EffectSituation {
        var resolved = situation
        guard surface != "screen-bar" else { resolved.device = nil; return resolved }
        let dot = store.core.devices.first { $0.id == surface && $0.kind == "dot" }
        if let dot, store.core.lights?.linked == true || dot.linked == true,
           let strip = store.core.devices.first(where: { $0.kind == "pro" && $0.isPresent }) {
            resolved.device = strip.id
        } else {
            resolved.device = surface
        }
        return resolved
    }

    @ViewBuilder
    private var outcome: some View {
        let resolved = resolvedSituation
        let outcome = EffectSituationResolver.resolve(resolved, in: store.assignments)
        VStack(alignment: .leading, spacing: 3) {
            if outcome.reserved {
                Text("\(situation.semantic == .asking ? "An ask" : "A failure") plays its reserved alert in every scene — no assignment can replace it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let winner = outcome.winner {
                let effect = store.catalog?.effect(winner.effectID)
                HStack(spacing: 6) {
                    if let effect {
                        LEDStripPreview(program: effect.preview?.program ?? "off", ledCount: effect.preview?.ledCount ?? 8,
                                        style: .band, dotSize: 5, showsBackground: false)
                            .frame(width: 34)
                    }
                    Text(Self.sentence(winner: winner, effect: effect, where: store.targetTitle(for: winner)))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if effect != nil, winner.effectID != "none" {
                        Button("Show") { store.selectedID = winner.effectID }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                ForEach(outcome.shadowed) { row in
                    Text("Shadows \(row.scope.label) · \(store.targetTitle(for: row)) (\(store.catalog?.effect(row.effectID)?.label ?? row.effectID))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                Text("No assignment names this; the monitor's own \(situation.semantic.label.lowercased()) light plays.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if resolved.device != nil, resolved.device != surface {
                Text("The Dot follows the strip while linked, so it plays what the strip plays.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// "Plays Aurora — Provider · Codex decides."
    static func sentence(winner: EffectAssignment, effect: EffectDefinition?, where title: String) -> String {
        let decider = winner.scope == .global ? "the Everywhere row decides" : "\(winner.scope.label) · \(title) decides"
        if winner.effectID == "none" { return "Nothing plays — \(decider)." }
        guard let effect else { return "\(decider.prefix(1).uppercased() + decider.dropFirst()), but its effect is not installed, so the monitor's default plays." }
        return "Plays \(effect.label) — \(decider)."
    }

    private func picker<Selection: Hashable, Content: View>(_ title: String, selection: Binding<Selection>,
                                                            @ViewBuilder content: () -> Content) -> some View {
        Picker(title, selection: selection, content: content)
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.caption)
    }
}
