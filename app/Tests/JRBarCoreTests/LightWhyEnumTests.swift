import Foundation
import Testing
@testable import JRBarCore

/// The documented `why` vocabulary with `why_detail`, and the fallbacks for
/// whatever an older daemon sends.
@Suite("Why this light: the documented vocabulary")
struct LightWhyEnumTests {
    static let now = Date(timeIntervalSince1970: 1_789_046_900)
    static let mainID = "claude:session:fca1eb06-f6d1-413e-aa5f-dd19d8e05973"
    /// The real daemon's Screen Bar fallback: a whole static program, brightest LED terracotta.
    static let realFallback = "brightness 91\n0:#0B0604; 1:#0B0604; 2:#0B0604; 3:#8D4D39; 4:#8D4D39; 5:#0B0604; 6:#0B0604; 7:#0B0604"

    static func detail(session: String? = mainID, label: String? = "jr-bar-67", provider: String? = "claude",
                       seconds: Double? = 83.3, factor: Double? = 1.0, dimming: [String] = []) -> CoreWhyDetail {
        CoreWhyDetail(session: session, label: label, provider: provider, secondsInState: seconds, brightnessFactor: factor, dimming: dimming)
    }

    static func lights(why: String, motion: String? = "continuous", fallback: String? = realFallback, detail: CoreWhyDetail? = nil) -> CoreLights {
        let surface = CoreLightSurface(program: "…", ledCount: 8, anchor: now.timeIntervalSince1970 - 83, motion: motion,
                                       staticFallback: fallback, brightness: 0.36, why: why, whyDetail: detail)
        return CoreLights(surfaces: ["hardware": surface, "screen_bar": surface, "dot": surface], linked: true)
    }

    static let main = CoreSession(id: mainID, provider: "claude", label: "jr-bar-67", shortId: "fca1eb06", cwd: "/Users/j/Downloads/JR-Bar",
                                  mode: "working", lifecycle: "active", since: now.timeIntervalSince1970 - 100, workers: 2)
    static let worker = CoreSession(id: "claude:agent:a764be9bccedce76b", provider: "claude", kind: "worker", parent: mainID,
                                    label: "jr-bar-67 worker a764be9b", shortId: "a764be9b", mode: "tool_running", lifecycle: "active")
    static let codexDone = CoreSession(id: "codex:session:01a08b62-8dbd-7410-babc-ab603738f9d8", provider: "codex", label: "Codex 01a08b62",
                                       shortId: "01a08b62", mode: "completed", lifecycle: "completed", since: now.timeIntervalSince1970 - 200,
                                       updatedAt: now.timeIntervalSince1970 - 30)
    /// The old daemon's label: the provider name plus the UUID.
    static let legacy = CoreSession(id: mainID, provider: "claude", label: "Claude fca1eb06-f6d1-413e-aa5f-dd19d8e05973",
                                    mode: "working", lifecycle: "active", since: now.timeIntervalSince1970 - 100)

    static func state(_ sessions: [CoreSession], asks: [CoreAsk] = [], usage: CoreUsage? = nil, escalation: CoreEscalation? = nil) -> CoreState {
        CoreState(generation: 1, now: now.timeIntervalSince1970, sessions: sessions, asks: asks, usage: usage, escalation: escalation)
    }

    static func explain(_ why: String, _ sessions: [CoreSession], detail: CoreWhyDetail? = nil, motion: String? = "continuous",
                        fallback: String? = realFallback, asks: [CoreAsk] = [], usage: CoreUsage? = nil, escalation: CoreEscalation? = nil,
                        settings: SettingsDocument? = nil) -> LightExplanation? {
        LightExplainer.explain(lights: lights(why: why, motion: motion, fallback: fallback, detail: detail),
                               state: state(sessions, asks: asks, usage: usage, escalation: escalation), settings: settings, now: now)
    }

    @Test("every documented word parses to itself; the old spellings map onto it")
    func vocabulary() {
        for kind in LightWhy.allCases { #expect(LightWhy.parse(kind.rawValue) == kind) }
        #expect(LightWhy.parse("needs_you") == .waiting)
        #expect(LightWhy.parse("completed_unseen") == .completed)
        #expect(LightWhy.parse("quota_crossed") == .capacity)
        #expect(LightWhy.parse("dnd") == .quiet)
        #expect(LightWhy.parse("escalation_final") == .escalation)
        #expect(LightWhy.parse("Sleep-Dim") == .sleepDim)
        #expect(LightWhy.parse("moon_phase") == nil)
        #expect(LightWhy.parse(nil) == nil)
    }

    @Test("working with why_detail reads from the detail, once, with no UUID")
    func workingDetail() throws {
        let explanation = try #require(Self.explain("working", [Self.main, Self.worker, Self.codexDone], detail: Self.detail()))
        #expect(explanation.kind == .working)
        #expect(explanation.motion == "Breathing orange")
        #expect(explanation.reason == "Claude jr-bar-67 is working")
        #expect(explanation.session == Self.mainID)
        #expect(!explanation.headline.contains("Claude Claude"))
        #expect(!explanation.headline.contains("f6d1"))
        #expect(explanation.details.contains { $0.label == "In this state" && $0.value == "1 min" })
    }

    @Test("the old provider-plus-UUID label never shows a UUID or a doubled provider")
    func legacyLabel() throws {
        let explanation = try #require(Self.explain("working", [Self.legacy], motion: "continuous", fallback: "off"))
        #expect(explanation.reason == "Claude fca1eb06 is working")
        #expect(explanation.motion == "Off")
        #expect(explanation.headline == "Off: Claude fca1eb06 is working")
    }

    @Test("a detail without a known session still names the label and provider")
    func detailOnly() throws {
        let detail = Self.detail(session: "codex:session:ghost", label: "Codex 01a08b62", provider: "codex", seconds: 12)
        let explanation = try #require(Self.explain("completed", [], detail: detail, motion: "finite", fallback: "#00FF66"))
        #expect(explanation.reason == "Codex 01a08b62 finished 12 s ago")
        #expect(explanation.motion == "Green sweep")
        #expect(explanation.session == "codex:session:ghost")
    }

    @Test("waiting, failed and escalation name the session and the wait")
    func attention() throws {
        var asking = Self.codexDone
        asking.mode = "waiting"; asking.lifecycle = "active"
        asking.ask = CoreAsk(kind: "permission", openedAt: Self.now.timeIntervalSince1970 - 45, summary: "Run: rm -rf build")
        let waiting = try #require(Self.explain("waiting", [asking, Self.main], detail: Self.detail(session: asking.id, label: "Codex 01a08b62", provider: "codex", seconds: 45)))
        #expect(waiting.headline == "Amber pulse: Codex 01a08b62 is waiting on you (permission, 45 s)")
        #expect(waiting.session == asking.id)

        var failed = Self.main
        failed.lifecycle = "failed"
        let failure = try #require(Self.explain("failed", [failed], detail: Self.detail(seconds: 5)))
        #expect(failure.headline == "Red flash: Claude jr-bar-67 failed 1 min ago")

        let escalation = try #require(Self.explain("escalation", [asking], escalation: CoreEscalation(stage: "menu_bar", since: Self.now.timeIntervalSince1970 - 120)))
        #expect(escalation.headline == "Bright amber pulse: Codex 01a08b62 has waited 2 min · escalation stage 2")
    }

    @Test("the dimming whys read their factor from why_detail")
    func dimming() throws {
        let battery = try #require(Self.explain("battery", [Self.main], detail: Self.detail(factor: 0.5, dimming: ["battery"])))
        #expect(battery.headline == "Dimmed: On battery, dimmed to 50%")
        #expect(battery.details.contains { $0.label == "Dimming" && $0.value == "battery · 50%" })
        let idleDim = try #require(Self.explain("idle_dim", [Self.main], detail: Self.detail(factor: 0.3, dimming: ["idle_dim"])))
        #expect(idleDim.reason == "Idle for 10 min, dimmed to 30%")
        let calendar = try #require(Self.explain("calendar", [Self.main], detail: Self.detail(factor: 0.6, dimming: ["calendar"]), motion: "static"))
        #expect(calendar.headline == "Steady orange: In a calendar event, dimmed to 60%")
        let sleep = try #require(Self.explain("sleep_dim", [Self.main]))
        #expect(sleep.headline == "Dimmed: Display asleep, keeping a faint glow")
    }

    @Test("capacity, reminder, preview and studio have lines")
    func others() throws {
        let usage = CoreUsage(refreshedAt: nil, providers: [CoreProviderUsage(id: "codex", windows: [CoreUsageWindow(key: "weekly", name: "7d", usedPct: 100)])])
        let capacity = try #require(Self.explain("capacity", [Self.main], usage: usage))
        #expect(capacity.headline == "Amber ember: Codex 7d window at 100%")
        let reminder = try #require(Self.explain("reminder", [Self.main], motion: "finite"))
        #expect(reminder.headline == "Orange sweep: A reminder is due")
        #expect(try #require(Self.explain("preview", [])).headline == "Preview: Previewing a program")
        #expect(try #require(Self.explain("studio", [])).headline == "Preview: Effect Studio is previewing")
        #expect(try #require(Self.explain("idle", [], motion: "breathe", fallback: "#020204")).headline == "Idle breath: Nothing is running")
    }

    @Test("capacity names a window with a reading, never one nobody measured")
    func capacityIgnoresUnknownWindows() throws {
        // Codex reports its weekly window without a number; Claude's 5h is
        // at 96 %. Reading the null as zero used to make Codex the calmest
        // provider and Claude the fullest -- but a `max` over zeros could
        // just as easily have named "Codex 7d window at 0%" as the reason
        // the light is amber.
        let mixed = CoreUsage(refreshedAt: nil, providers: [
            CoreProviderUsage(id: "codex", windows: [CoreUsageWindow(key: "weekly", name: "7d", usedPct: nil)]),
            CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(key: "five_hour", name: "5h", usedPct: 96)]),
        ])
        #expect(try #require(Self.explain("capacity", [Self.main], usage: mixed)).headline == "Amber ember: Claude 5h window at 96%")

        // Nothing measured at all: the generic line, and no invented number.
        let blind = CoreUsage(refreshedAt: nil, providers: [
            CoreProviderUsage(id: "codex", windows: [CoreUsageWindow(key: "weekly", name: "7d", usedPct: nil)]),
        ])
        let generic = try #require(Self.explain("capacity", [Self.main], usage: blind))
        #expect(generic.reason == "A usage window is nearly spent")
        #expect(!generic.headline.contains("0%"))
    }

    @Test("an unknown why falls back to the motion and the top session, never a UUID")
    func unknownFallback() throws {
        let unknown = try #require(Self.explain("moon_phase", [Self.codexDone, Self.legacy]))
        #expect(unknown.kind == .unknown)
        #expect(unknown.why == "moon_phase")
        #expect(unknown.headline == "Breathing orange: Claude fca1eb06 is working (moon phase)")
        #expect(unknown.session == Self.mainID)
        let explicit = try #require(Self.explain("unknown", [Self.codexDone]))
        #expect(explicit.headline == "Breathing orange: Codex 01a08b62 finished")
        let nobody = try #require(Self.explain("unknown", []))
        #expect(nobody.reason == "No reason given")
        let asking = try #require(Self.explain("moon_phase", [Self.main], asks: [CoreAsk(session: Self.mainID, kind: "permission", openedAt: Self.now.timeIntervalSince1970 - 5, summary: "?")]))
        #expect(asking.reason == "Claude jr-bar-67 is waiting on you (moon phase)")
    }

    @Test("the fallback colour comes from the brightest LED of a whole program")
    func programColour() {
        #expect(LightExplainer.dominantColourName(Self.realFallback) == "orange")
        #expect(LightExplainer.dominantColourName("#2B8FFF") == "blue")
        #expect(LightExplainer.dominantColourName("brightness 40\n0:#000000; 1:#000000") == "dim")
        #expect(LightExplainer.dominantColourName("off") == "off")
        #expect(LightExplainer.dominantColourName("repeat") == nil)
        #expect(LightExplainer.colourName("#D97757") == "orange")
        #expect(LightExplainer.colourName("#FF3A00") == "red")
    }

    @Test("why_detail decodes with every field optional and tolerant dimming")
    func decoding() throws {
        let json = #"{"program":"x","led_count":8,"why":"working","why_detail":{"session":"s","label":"l","provider":"claude","seconds_in_state":83.3,"brightness_factor":1.0,"dimming":["idle_dim",{"name":"battery"},7]}}"#
        let surface = try JSONDecoder().decode(CoreLightSurface.self, from: Data(json.utf8))
        let detail = try #require(surface.whyDetail)
        #expect(detail.session == "s" && detail.label == "l" && detail.provider == "claude")
        #expect(detail.secondsInState == 83.3)
        #expect(detail.dimming == ["idle_dim", "battery"])
        let bare = try JSONDecoder().decode(CoreLightSurface.self, from: Data(#"{"program":"x","why":"idle","why_detail":{}}"#.utf8))
        #expect(bare.whyDetail?.dimming == [])
        let broken = try JSONDecoder().decode(CoreLightSurface.self, from: Data(#"{"program":"x","why":"idle","why_detail":"nope"}"#.utf8))
        #expect(broken.whyDetail == nil)
        #expect(broken.why == "idle")
    }
}
