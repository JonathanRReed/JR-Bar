import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The connections strip's pure half: tone decisions over the daemon's
/// published state — core link, nodes, devices, providers. The chips and
/// inspector are SwiftUI and stay untested here by design.
@Suite struct OverviewLinksTests {

    // MARK: Core link

    @Test func coreLinkReflectsConnection() {
        var s = OverviewLinkage.Snapshot()
        s.connected = true
        s.coreVersion = "0.9.8"
        s.corePID = 4242
        s.connectedAt = Date(timeIntervalSinceNow: -3600)
        s.inFlight = 2
        let link = OverviewLinkage.links(s).first { $0.group == .core }
        #expect(link?.tone == .good)
        #expect(link?.title == "Core 0.9.8")
        #expect(link?.facts.contains { $0.label == "Daemon pid" && $0.value == "4242" } == true)
        #expect(link?.facts.contains { $0.label == "In flight" && $0.value == "2" } == true)
        #expect(link?.facts.contains { $0.label == "Connected for" } == true)
    }

    @Test func coreLinkConnectingAndDown() {
        var s = OverviewLinkage.Snapshot()
        s.connecting = true
        #expect(OverviewLinkage.links(s).first { $0.group == .core }?.tone == .busy)

        s.connecting = false
        s.offlineReason = "socket went away"
        let down = OverviewLinkage.links(s).first { $0.group == .core }
        #expect(down?.tone == .down)
        #expect(down?.facts.contains { $0.label == "Last error" && $0.value == "socket went away" } == true)
    }

    // MARK: Nodes

    @Test func localNodeAlwaysPresent() {
        var s = OverviewLinkage.Snapshot()
        s.connected = true
        s.localName = "Studio"
        s.localSessions = 3
        let node = OverviewLinkage.links(s).first { $0.id == "node:local" }
        #expect(node?.title == "Studio")
        #expect(node?.subtitle == "3 sessions")
        #expect(node?.tone == .good)
    }

    @Test func peerReachabilitySetsTone() {
        var s = OverviewLinkage.Snapshot()
        s.peers = [
            CorePeer(machine: "workshop", host: "workshop.tail", reachable: true, rows: 2),
            CorePeer(machine: "attic", reachable: false, rows: 0, failure: "ssh_timeout"),
        ]
        let links = OverviewLinkage.links(s)
        let workshop = links.first { $0.id == "node:workshop" }
        let attic = links.first { $0.id == "node:attic" }
        #expect(workshop?.tone == .good)
        #expect(workshop?.subtitle == "2 sessions")
        #expect(attic?.tone == .down)
        #expect(attic?.subtitle == "unreachable")
        #expect(attic?.facts.contains { $0.label == "Failure" && $0.value == "ssh timeout" } == true)
    }

    // MARK: Devices

    @Test func deviceTones() {
        var s = OverviewLinkage.Snapshot()
        s.connected = true
        s.devices = [
            CoreDevice(id: "pro1", kind: "pro", name: "SidePulse", leds: 32, connected: true, brightness: 0.8),
            CoreDevice(id: "bar", kind: "screen_bar", name: "Screen Bar", enabled: true),
            CoreDevice(id: "dot1", kind: "dot", name: "PulseDot", connected: false, error: "write timeout"),
        ]
        let links = OverviewLinkage.links(s)
        #expect(links.first { $0.id == "device:pro1" }?.tone == .good)
        #expect(links.first { $0.id == "device:bar" }?.tone == .good)
        let dot = links.first { $0.id == "device:dot1" }
        #expect(dot?.tone == .warn)
        #expect(dot?.facts.contains { $0.label == "Error" && $0.value == "write timeout" } == true)
        #expect(links.first { $0.id == "device:pro1" }?.facts
            .contains { $0.label == "Brightness" && $0.value == "80%" } == true)
    }

    @Test func deckJoinsDevices() {
        var s = OverviewLinkage.Snapshot()
        s.connected = true
        s.deck = DeckDevice(name: "Creator Micro 2", transport: .usb, connected: true, approved: false)
        let link = OverviewLinkage.links(s).first { $0.id == "device:deck" }
        #expect(link?.group == .devices)
        #expect(link?.title == "Creator Micro 2")
        #expect(link?.subtitle == "Connected")
        #expect(link?.tone == .warn)
    }

    // MARK: Providers

    @Test func providerIncidentBeatsState() {
        var s = OverviewLinkage.Snapshot()
        s.providers = [
            CoreProviderUsage(
                id: "claude",
                windows: [CoreUsageWindow(name: "5h", usedPct: 61)],
                state: "ready",
                incident: "Anthropic: Elevated errors"),
            CoreProviderUsage(id: "codex", windows: [CoreUsageWindow(name: "5h", usedPct: 12)], state: "ready"),
            CoreProviderUsage(id: "grok", state: "not_signed_in"),
        ]
        let links = OverviewLinkage.links(s)
        let claude = links.first { $0.id == "provider:claude" }
        #expect(claude?.usageStatus == .incident)
        #expect(claude?.subtitle == "Incident")
        #expect(claude?.facts.contains { $0.label == "Incident" && $0.value.contains("Elevated") } == true)
        #expect(links.first { $0.id == "provider:codex" }?.tone == .good)
        #expect(links.first { $0.id == "provider:grok" }?.usageStatus == .needsSignIn)
    }

    @Test func providerPercentReadsInSubtitle() {
        var s = OverviewLinkage.Snapshot()
        s.providers = [CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 40)], state: "ready")]
        let link = OverviewLinkage.links(s).first { $0.id == "provider:claude" }
        #expect(link?.subtitle == "40% used")
        #expect(link?.facts.contains { $0.label == "Headline" && $0.value.contains("5h") } == true)
    }

    @Test func aStaleReadingIsMarkedAndTwoAccountsAreTold() {
        var s = OverviewLinkage.Snapshot()
        s.providers = [
            CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 40)], state: "stale"),
            CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 10)], state: "ready", instance: "work"),
            CoreProviderUsage(id: "opencode", windows: [], state: "ready", quotaSource: false),
        ]
        let links = OverviewLinkage.links(s)
        let stale = links.first { $0.id == "provider:claude" }
        #expect(stale?.subtitle == "40% used · Stale")
        #expect(stale?.usageStatus == .stale)
        let work = links.first { $0.id == "provider:claude|work" }
        #expect(work?.title == "Claude · work")
        #expect(work?.tone == .good)
        let none = links.first { $0.id == "provider:opencode" }
        #expect(none?.subtitle == "No quota source")
        #expect(none?.facts.contains { $0.label == "Quota" } == true)
    }

    // MARK: Order

    @Test func groupsComeInOrder() {
        var s = OverviewLinkage.Snapshot()
        s.connected = true
        s.peers = [CorePeer(machine: "workshop", reachable: true, rows: 1)]
        s.devices = [CoreDevice(id: "pro1", kind: "pro", connected: true)]
        s.providers = [CoreProviderUsage(id: "claude")]
        let groups = OverviewLinkage.links(s).map(\.group)
        #expect(groups == [.core, .nodes, .nodes, .devices, .providers])
    }
}
