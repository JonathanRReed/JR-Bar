import Foundation
import JRBarCore
import JRBarUI

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
    var usageStatus: UsageStatus? = nil

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
        var usableState: Bool?
        var stateRejected: String?
        var stateUsable: Bool { usableState ?? connected }
        var connecting = false
        var offlineReason: String?
        var coreVersion: String?
        var corePID: Int?
        var connectedAt: Date?
        var inFlight = 0
        /// Last-state-frame age and the stale verdict (`CoreModel`'s
        /// `stateAge`/`stateIsStale`) — an open socket with no frames is
        /// "quiet", not healthy.
        var stateAge: TimeInterval?
        var stateStale = false
        var localName = "This Mac"
        var localSessions = 0
        var peers: [CorePeer] = []
        var devices: [CoreDevice] = []
        var providers: [CoreProviderUsage] = []
        var deck: DeckDevice?
        var deckEnabled: Bool?
    }

    static func links(_ s: Snapshot, now: Date = Date()) -> [OverviewLink] {
        var out: [OverviewLink] = [coreLink(s, now: now), localNode(s)]
        out.append(contentsOf: s.peers.map(peerLink))
        out.append(contentsOf: s.devices.map { deviceLink($0, live: s.stateUsable) })
        if let deck = s.deck { out.append(deckLink(deck, enabled: s.deckEnabled, live: s.stateUsable)) }
        out.append(contentsOf: s.providers.map(providerLink))
        if s.usableState == false {
            for index in out.indices where out[index].group != .core {
                if out[index].tone == .good { out[index].tone = .warn }
                if out[index].usageStatus == .ready { out[index].usageStatus = .stale }
                out[index].facts.append(.init("Reading", "on record; monitor state unavailable"))
            }
        }
        return out
    }

    // MARK: Core

    private static func coreLink(_ s: Snapshot, now: Date) -> OverviewLink {
        var facts: [OverviewLinkFact] = []
        facts.append(.init("Link", s.connected ? "Connected" : (s.connecting ? MonitorWords.reconnecting : "Not connected")))
        if let version = s.coreVersion { facts.append(.init("Version", version)) }
        if let pid = s.corePID { facts.append(.init("Daemon pid", "\(pid)")) }
        if s.connected, let at = s.connectedAt {
            facts.append(.init("Connected for", AgentMonitorFeed.ageText(now.timeIntervalSince(at))))
        }
        if s.connected, s.stateStale, let age = s.stateAge {
            facts.append(.init("Last update", "\(AgentMonitorFeed.ageText(age)) ago — the monitor is quiet"))
        }
        if s.inFlight > 0 { facts.append(.init("In flight", "\(s.inFlight)")) }
        if let reason = s.offlineReason, !reason.isEmpty, !s.connected {
            facts.append(.init("Last error", reason))
        }
        if let reason = s.stateRejected { facts.append(.init("Update rejected", reason)) }
        if s.connected, !s.stateUsable {
            facts.append(.init("State", s.stateRejected == nil ? "waiting for an update" : "last update unreadable"))
        }
        let tone: OverviewLink.Tone
        let subtitle: String
        if s.connected, !s.stateUsable {
            tone = s.stateRejected == nil ? .busy : .warn
            subtitle = s.stateRejected == nil ? "Connected · waiting for an update" : "Connected · update unreadable"
        } else if s.connected {
            tone = s.stateStale ? .warn : .good
            subtitle = s.stateStale ? "Connected · quiet" : "Connected"
        } else {
            tone = s.connecting ? .busy : .down
            subtitle = s.connecting ? MonitorWords.reconnecting : "Not connected"
        }
        return OverviewLink(
            id: "core", group: .core,
            symbol: "bolt.horizontal.circle.fill",
            title: s.coreVersion.map { "Core \($0)" } ?? "Core",
            subtitle: subtitle,
            tone: tone, facts: facts)
    }

    // MARK: Nodes

    private static func localNode(_ s: Snapshot) -> OverviewLink {
        OverviewLink(
            id: "node:local", group: .nodes,
            symbol: "desktopcomputer",
            title: s.localName,
            subtitle: s.stateUsable ? (s.localSessions == 1 ? "1 session" : "\(s.localSessions) sessions") : "\(s.localSessions) sessions on record",
            tone: s.stateUsable ? .good : .idle,
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

    private static func deviceLink(_ device: CoreDevice, live: Bool) -> OverviewLink {
        let state = device.kind == "screen_bar"
            ? DeviceConnectionState.screenBar(device, live: live)
            : DeviceConnectionState.device(device, live: live)
        var facts: [OverviewLinkFact] = [
            .init("Kind", device.kind.replacingOccurrences(of: "_", with: " ")),
            .init("State", state.rawValue),
        ]
        if let leds = device.leds { facts.append(.init("LEDs", "\(leds)")) }
        if let fraction = device.brightnessFraction {
            facts.append(.init("Brightness", "\(Int((fraction * 100).rounded()))%"))
        }
        if let linked = device.linked { facts.append(.init("Linked", linked ? "yes" : "no")) }
        var tone: OverviewLink.Tone = state.isConnected ? .good : .idle
        if let error = device.error, !error.isEmpty {
            facts.append(.init("Error", error))
            tone = .warn
        }
        return OverviewLink(
            id: "device:\(device.id)", group: .devices,
            symbol: deviceSymbol(for: device.kind),
            title: DeviceConnectionState.name(kind: device.kind, fallback: device.name),
            subtitle: state.rawValue,
            tone: tone, facts: facts)
    }

    private static func deckLink(_ device: DeckDevice, enabled: Bool?, live: Bool) -> OverviewLink {
        let state = DeviceConnectionState.creatorMicro(
            DeckState(device: device, settings: DeckSettings(enabled: enabled ?? true)), live: live)
        var facts: [OverviewLinkFact] = [
            .init("State", state.rawValue),
            .init("Approved", device.approved ? "yes" : "no"),
        ]
        if let transport = device.transport { facts.append(.init("Transport", transport.label)) }
        if let serial = device.serial { facts.append(.init("Serial", serial)) }
        var tone: OverviewLink.Tone = state.isConnected ? (device.approved ? .good : .warn) : .idle
        if let conflict = device.conflict {
            facts.append(.init("Conflict", conflict.replacingOccurrences(of: "_", with: " ")))
            tone = .warn
        }
        return OverviewLink(
            id: "device:deck", group: .devices,
            symbol: "rectangle.grid.3x2.fill",
            title: DeviceConnectionState.name(kind: "deck"),
            subtitle: state.rawValue,
            tone: tone, facts: facts)
    }

    // MARK: Providers

    private static func providerLink(_ provider: CoreProviderUsage) -> OverviewLink {
        let status = UsageStatus.provider(provider)
        var facts: [OverviewLinkFact] = [.init("State", status.word)]
        if let fidelity = provider.fidelity { facts.append(.init("Fidelity", fidelity)) }
        if let window = provider.headlineWindow, let pct = window.usedPct {
            var word = "\(UsageWindowLabel.wholeUsed(pct))% used"
            if !window.name.isEmpty { word += " · \(window.name)" }
            facts.append(.init("Headline", word))
        }
        if let credits = provider.creditsRemaining {
            facts.append(.init("Credits", "\(Int(saturating: credits.rounded()))"))
        }
        if let incident = provider.incident, !incident.isEmpty {
            facts.append(.init("Incident", incident))
        }
        if let action = provider.action, !action.isEmpty {
            facts.append(.init("Action", action))
        }

        let tone: OverviewLink.Tone = status == .ready ? .good : .idle
        let style = ProviderStyle.style(for: provider.id)
        var subtitle = status.word
        if [.ready, .stale].contains(status), let pct = provider.headlineWindow?.usedPct {
            subtitle = UsageNumber.percent(pct) + " used"
            if status == .stale { subtitle += " · " + status.word }
        }
        if status == .noQuotaSource { facts.append(.init("Quota", status.word)) }
        // Two accounts of one provider are two chips; the tag says which.
        let title = UsageSourceNotes.rowTag(provider.instance).map { "\(style.name) · \($0)" } ?? style.name
        return OverviewLink(
            id: "provider:\(provider.identity)", group: .providers,
            symbol: "gauge.with.dots.needle.67percent",
            title: title,
            subtitle: subtitle,
            tone: tone, facts: facts, usageStatus: status)
    }
}
