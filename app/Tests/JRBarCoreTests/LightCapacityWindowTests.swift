import Foundation
import Testing
@testable import JRBarCore

/// "Why this light" for a capacity light names the window the daemon used:
/// bindable, measured, and not past its reset (docs/CORE-PROTOCOL.md, the
/// `constrained` bullet). A window whose reset has passed describes a window
/// that no longer exists, so it is never named as the reason, however full it
/// last read; when every window has lapsed the line says so in words.
/// Synthetic providers and windows throughout.
@Suite("Why this light: the capacity window")
struct LightCapacityWindowTests {
    private static let now = LightWhyEnumTests.now
    private static var epoch: Double { now.timeIntervalSince1970 }

    private static func live(_ key: String, _ name: String, _ used: Double?, in hours: Double = 2,
                             bindable: Bool = true) -> CoreUsageWindow {
        CoreUsageWindow(key: key, name: name, usedPct: used, resetsAt: epoch + hours * 3600, bindable: bindable)
    }

    private static func lapsed(_ key: String, _ name: String, _ used: Double?, ago hours: Double = 1) -> CoreUsageWindow {
        CoreUsageWindow(key: key, name: name, usedPct: used, resetsAt: epoch - hours * 3600)
    }

    private static func capacity(_ providers: [CoreProviderUsage]) throws -> LightExplanation {
        let usage = CoreUsage(refreshedAt: nil, providers: providers)
        return try #require(LightWhyEnumTests.explain("capacity", [LightWhyEnumTests.main], usage: usage))
    }

    private static let allLapsed = "Every usage window has reset since its last reading"

    @Test("the daemon's constrained pick is the window named, not a lapsed one that last read fuller")
    func constrainedPickWinsOverALapsedWindow() throws {
        let claude = CoreProviderUsage(
            id: "claude",
            windows: [Self.live("five_hour", "5h", 96), Self.lapsed("weekly", "7d", 100)],
            constrained: CoreConstrainedLane(id: "five_hour", name: "5h", usedPct: 96, reason: "only_measured", candidates: 1))
        let explanation = try Self.capacity([claude])
        #expect(explanation.headline == "Amber ember: Claude 5h window at 96%")
    }

    @Test("without a constrained pick the same rule holds: a lapsed window never wins")
    func fallbackSkipsALapsedWindow() throws {
        let claude = CoreProviderUsage(id: "claude", windows: [Self.live("five_hour", "5h", 96), Self.lapsed("weekly", "7d", 100)])
        #expect(try Self.capacity([claude]).reason == "Claude 5h window at 96%")
    }

    @Test("a window that resets exactly now has lapsed")
    func resetAtNowIsLapsed() throws {
        let edge = CoreUsageWindow(key: "weekly", name: "7d", usedPct: 100, resetsAt: Self.epoch)
        let claude = CoreProviderUsage(id: "claude", windows: [Self.live("five_hour", "5h", 40), edge])
        #expect(try Self.capacity([claude]).reason == "Claude 5h window at 40%")
    }

    @Test("a window with no reset time never lapses")
    func noResetTimeStaysCurrent() throws {
        let open = CoreUsageWindow(key: "credits", name: "Credits", usedPct: 88)
        let codex = CoreProviderUsage(id: "codex", windows: [open, Self.live("five_hour", "5h", 20)])
        #expect(try Self.capacity([codex]).reason == "Codex Credits window at 88%")
    }

    @Test("every window lapsed says so in plain words and names no window or number")
    func everyWindowLapsed() throws {
        let claude = CoreProviderUsage(id: "claude", windows: [Self.lapsed("five_hour", "5h", 97), Self.lapsed("weekly", "7d", 100)])
        let codex = CoreProviderUsage(id: "codex", windows: [Self.lapsed("weekly", "7d", 91)])
        let explanation = try Self.capacity([claude, codex])
        #expect(explanation.reason == Self.allLapsed)
        #expect(explanation.motion == "Amber ember")
        #expect(!explanation.headline.contains("%"))
        #expect(!explanation.headline.contains("7d"))
    }

    @Test("a lapsed pick from the daemon, named before its reset, is not carried past it")
    func constrainedPickThatLapsedOnTheAppClock() throws {
        // The daemon named the 5h window while it still had time; the app's
        // clock is now past its reset.
        let stale = CoreProviderUsage(
            id: "claude",
            windows: [Self.lapsed("five_hour", "5h", 96, ago: 0.01)],
            constrained: CoreConstrainedLane(id: "five_hour", name: "5h", usedPct: 96,
                                             resetsAt: Self.epoch - 36, reason: "only_measured", candidates: 1))
        #expect(try Self.capacity([stale]).reason == Self.allLapsed)
        let sibling = CoreProviderUsage(
            id: "claude",
            windows: [Self.lapsed("five_hour", "5h", 96, ago: 0.01), Self.live("weekly", "7d", 61)],
            constrained: CoreConstrainedLane(id: "five_hour", name: "5h", usedPct: 96, reason: "least_headroom", candidates: 2))
        #expect(try Self.capacity([sibling]).reason == "Claude 7d window at 61%")
    }

    @Test("a window the provider's catalog does not know is evidence, never the reason")
    func unbindableWindowIsNotNamed() throws {
        let claude = CoreProviderUsage(id: "claude", windows: [
            Self.live("fable-only", "7d Fable", 100, bindable: false), Self.live("five_hour", "5h", 52)])
        #expect(try Self.capacity([claude]).reason == "Claude 5h window at 52%")
        // Only unbindable windows measured: nothing applicable, the generic line.
        let only = CoreProviderUsage(id: "claude", windows: [Self.live("fable-only", "7d Fable", 100, bindable: false)])
        let generic = try Self.capacity([only])
        #expect(generic.reason == "A usage window is nearly spent")
        #expect(!generic.headline.contains("%"))
    }

    @Test("across providers the live windows compete; a lapsed provider does not")
    func acrossProviders() throws {
        let claude = CoreProviderUsage(id: "claude", windows: [Self.lapsed("weekly", "7d", 100)])
        let codex = CoreProviderUsage(id: "codex", windows: [Self.live("weekly", "7d", 83)])
        #expect(try Self.capacity([claude, codex]).reason == "Codex 7d window at 83%")
        let fuller = CoreProviderUsage(id: "gemini", windows: [Self.live("daily", "Daily", 91)])
        #expect(try Self.capacity([claude, codex, fuller]).reason == "Gemini Daily window at 91%")
    }

    @Test("a tie reads as the daemon's runway does: the provider that sorts first")
    func tieGoesToTheFirstProviderId() throws {
        let zed = CoreProviderUsage(id: "zed", windows: [Self.live("daily", "Daily", 90)])
        let codex = CoreProviderUsage(id: "codex", windows: [Self.live("weekly", "7d", 90)])
        #expect(try Self.capacity([zed, codex]).reason == "Codex 7d window at 90%")
        #expect(try Self.capacity([codex, zed]).reason == "Codex 7d window at 90%")
    }

    @Test("with nothing measured the line stays generic and invents no number")
    func nothingMeasured() throws {
        let blind = CoreProviderUsage(id: "codex", windows: [Self.live("weekly", "7d", nil)])
        let generic = try Self.capacity([blind])
        #expect(generic.reason == "A usage window is nearly spent")
        let none = try #require(LightWhyEnumTests.explain("capacity", [LightWhyEnumTests.main]))
        #expect(none.reason == "A usage window is nearly spent")
    }

    @Test("a healthy window is named as it always was")
    func healthyWindowIsUnchanged() throws {
        let codex = CoreProviderUsage(
            id: "codex", windows: [Self.live("five_hour", "5h", 71.6), Self.live("weekly", "7d", 30)],
            constrained: CoreConstrainedLane(id: "five_hour", name: "5h", usedPct: 71.6, reason: "least_headroom", candidates: 2))
        #expect(try Self.capacity([codex]).headline == "Amber ember: Codex 5h window at 72%")
    }
}
