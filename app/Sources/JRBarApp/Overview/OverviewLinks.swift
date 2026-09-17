import Foundation
import JRBarCore

/// A labelled fact on a connection's inspector card.
struct OverviewLinkFact: Hashable, Sendable {
    var label: String
    var value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// One live wire the Overview reports — the core link itself, a node in
/// the fleet, a light device, the deck, or a usage provider. Built from
/// the daemon's `state` push, so the strip is never a second source that
/// could disagree with the rows.
struct OverviewLink: Identifiable, Hashable, Sendable {
    enum Group: String, Sendable, CaseIterable {
        case core, nodes, devices, providers

        var title: String {
            switch self {
            case .core: "Core"
            case .nodes: "Nodes"
            case .devices: "Devices"
            case .providers: "Providers"
            }
        }
    }

    /// The status dot's verdict. `good` live, `busy` connecting,
    /// `warn` an incident or error the link survives, `down`
    /// unreachable/signed out, `idle` present but quiet.
    enum Tone: String, Sendable {
        case good, busy, warn, down, idle
    }

    var id: String
    var group: Group
    /// SF Symbol for the chip; providers resolve their own tile instead.
    var symbol: String
    var title: String
    /// Second line in the inspector card / trailing word in the chip's
    /// tooltip — the shortest honest summary ("3 sessions", "linked").
    var subtitle: String?
    var tone: Tone
    var facts: [OverviewLinkFact]

    /// The tooltip text: title, subtitle, then every fact on its own
    /// line — what `help()` says and VoiceOver repeats.
    var helpText: String {
        var lines = [subtitle.map { "\(title) — \($0)" } ?? title]
        lines.append(contentsOf: facts.map { "\($0.label): \($0.value)" })
        return lines.joined(separator: "\n")
    }
}

/// Builds the Overview's connections strip from one lifted snapshot of
/// the daemon's published state. Pure — `CoreModel` stays in the store,
/// tests exercise every tone without a socket.
enum OverviewLinkage {
    /// What the builder needs, lifted off `CoreModel` so the decision
    /// table stays pure. `localName` is the host's own name — the one
    /// node that exists whether or not the daemon is connected.
    struct Snapshot: Sendable {
        var connected = false
        var connecting = false
        var offlineReason: String?
        var coreVersion: String?
        var corePID: Int?
        var connectedAt: Date?
        var inFlight = 0
        var localName = "This Mac"
        var localSessions = 0
        var peers: [CorePeer] = []
        var devices: [CoreDevice] = []
        var providers: [CoreProviderUsage] = []
        var deck: DeckDevice?
    }

    static func links(_ s: Snapshot, now: Date = Date()) -> [OverviewLink] {
        var out: [OverviewLink] = [coreLink(s, now: now), localNode(s)]
        out.append(contentsOf: s.peers.map(peerLink))
        out.append(contentsOf: s.devices.map(deviceLink))
        if let deck = s.deck { out.append(deckLink(deck)) }
        out.append(contentsOf: s.providers.map(providerLink))
        return out
    }

    // MARK: Core

    private static func coreLink(_ s: Snapshot, now: Date) -> OverviewLink {
        var facts: [OverviewLinkFact] = []
        facts.append(.init("Link", s.connected ? "connected" : (s.connecting ? "connecting" : "offline")))
        if let version = s.coreVersion { facts.append(.init("Version", version)) }
        if let pid = s.corePID { facts.append(.init("Daemon pid", "\(pid)")) }
        if s.connected, let at = s.connectedAt {
            facts.append(.init("Connected for", AgentMonitorFeed.ageText(now.timeIntervalSince(at))))
        }
        if s.inFlight > 0 { facts.append(.init("In flight", "\(s.inFlight)")) }
        if let reason = s.offlineReason, !reason.isEmpty, !s.connected {
            facts.append(.init("Last error", reason))
        }
        let tone: OverviewLink.Tone = s.connected ? .good : (s.connecting ? .busy : .down)
        return OverviewLink(
            id: "core", group: .core,
            symbol: "bolt.horizontal.circle.fill",
            title: s.coreVersion.map { "Core \($0)" } ?? "Core",
            subtitle: s.connected ? "connected" : (s.connecting ? "connecting" : "offline"),
            tone: tone, facts: facts)
    }

    // MARK: Nodes

    private static func localNode(_ s: Snapshot) -> OverviewLink {
        OverviewLink(
            id: "node:local", group: .nodes,
            symbol: "desktopcomputer",
            title: s.localName,
            subtitle: s.localSessions == 1 ? "1 session" : "\(s.localSessions) sessions",
            tone: s.connected ? .good : .idle,
            facts: [
                .init("Role", "this Mac"),
                .init("Sessions", "\(s.localSessions) on record"),
            ])
    }

    private static func peerLink(_ peer: CorePeer) -> OverviewLink {
        var facts: [OverviewLinkFact] = [
            .init("State", peer.reachable ? "reachable" : "unreachable"),
            .init("Sessions", "\(peer.rows) on record"),
        ]
        if let host = peer.host, !host.isEmpty { facts.append(.init("Host", host)) }
        if let failure = peer.failure, !failure.isEmpty {
            facts.append(.init("Failure", failure.replacingOccurrences(of: "_", with: " ")))
        }
        return OverviewLink(
            id: "node:\(peer.machine)", group: .nodes,
            symbol: "network",
            title: peer.machine,
            subtitle: peer.reachable
                ? "\(peer.rows) session\(peer.rows == 1 ? "" : "s")"
                : "unreachable",
            tone: peer.reachable ? .good : .down,
            facts: facts)
    }

    // MARK: Devices

    private static func deviceSymbol(for kind: String) -> String {
        switch kind {
        case "pro": "light.ribbon.fill"
        case "dot": "circle.grid.3x3.fill"
        case "screen_bar": "menubar.rectangle"
        default: "lightbulb.fill"
        }
    }

    private static func deviceLink(_ device: CoreDevice) -> OverviewLink {
        var facts: [OverviewLinkFact] = [
            .init("Kind", device.kind.replacingOccurrences(of: "_", with: " ")),
            .init("State", device.isPresent ? "connected" : "disconnected"),
        ]
        if let leds = device.leds { facts.append(.init("LEDs", "\(leds)")) }
        if let fraction = device.brightnessFraction {
            facts.append(.init("Brightness", "\(Int((fraction * 100).rounded()))%"))
        }
        if let linked = device.linked { facts.append(.init("Linked", linked ? "yes" : "no")) }
        var tone: OverviewLink.Tone = device.isPresent ? .good : .idle
        if let error = device.error, !error.isEmpty {
            facts.append(.init("Error", error))
            tone = .warn
        }
        return OverviewLink(
            id: "device:\(device.id)", group: .devices,
            symbol: deviceSymbol(for: device.kind),
            title: device.name ?? device.kind.replacingOccurrences(of: "_", with: " ").capitalized,
            subtitle: device.isPresent ? "connected" : "disconnected",
            tone: tone, facts: facts)
    }

    private static func deckLink(_ device: DeckDevice) -> OverviewLink {
        var facts: [OverviewLinkFact] = [
            .init("State", device.connected ? "connected" : "disconnected"),
            .init("Approved", device.approved ? "yes" : "no"),
        ]
        if let transport = device.transport { facts.append(.init("Transport", transport.label)) }
        if let serial = device.serial { facts.append(.init("Serial", serial)) }
        var tone: OverviewLink.Tone = device.connected ? (device.approved ? .good : .warn) : .idle
        if let conflict = device.conflict {
            facts.append(.init("Conflict", conflict.replacingOccurrences(of: "_", with: " ")))
            tone = .warn
        }
        return OverviewLink(
            id: "device:deck", group: .devices,
            symbol: "rectangle.grid.3x2.fill",
            title: device.name ?? "Deck",
            subtitle: device.connected
                ? (device.approved ? "connected" : "awaiting approval")
                : "disconnected",
            tone: tone, facts: facts)
    }

    // MARK: Providers

    private static func providerLink(_ provider: CoreProviderUsage) -> OverviewLink {
        var facts: [OverviewLinkFact] = []
        if let state = provider.state, !state.isEmpty {
            facts.append(.init("State", state.replacingOccurrences(of: "_", with: " ")))
        }
        if let fidelity = provider.fidelity { facts.append(.init("Fidelity", fidelity)) }
        if let window = provider.headlineWindow, let pct = window.usedPct {
            var word = "\(Int(pct.rounded()))% used"
            if !window.name.isEmpty { word += " · \(window.name)" }
            facts.append(.init("Headline", word))
        }
        if let credits = provider.creditsRemaining {
            facts.append(.init("Credits", "\(Int(credits.rounded()))"))
        }
        if let incident = provider.incident, !incident.isEmpty {
            facts.append(.init("Incident", incident))
        }
        if let action = provider.action, !action.isEmpty {
            facts.append(.init("Action", action))
        }

        var tone: OverviewLink.Tone = .idle
        if provider.incident?.isEmpty == false { tone = .warn }
        else if provider.isSignedOut { tone = .down }
        else if let state = provider.state?.lowercased(),
                state == "error" || state == "failed" { tone = .down }
        else if !provider.windows.isEmpty || provider.creditsRemaining != nil { tone = .good }

        let style = ProviderStyle.style(for: provider.id)
        var subtitle = provider.state?.replacingOccurrences(of: "_", with: " ")
        if let pct = provider.headlineWindow?.usedPct {
            subtitle = "\(Int(pct.rounded()))% used"
        }
        if provider.incident?.isEmpty == false { subtitle = "incident" }
        return OverviewLink(
            id: "provider:\(provider.identity)", group: .providers,
            symbol: "gauge.with.dots.needle.67percent",
            title: style.name,
            subtitle: subtitle,
            tone: tone, facts: facts)
    }
}
