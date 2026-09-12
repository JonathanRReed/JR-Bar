import Foundation
import Testing
@testable import JRBarCore

@Suite("Why this light")
struct LightExplanationTests {
    static let now = Date(timeIntervalSince1970: 1_788_982_900)

    static func lights(why: String, motion: String? = "beat", fallback: String? = "#FF3A00") -> CoreLights {
        let surface = CoreLightSurface(program: "off 160ms cosine\n#FF3A00 1.6s pulse\nrepeat", ledCount: 8,
                                       anchor: now.timeIntervalSince1970 - 12, motion: motion, staticFallback: fallback, brightness: 0.79, why: why)
        return CoreLights(surfaces: ["hardware": surface, "screen_bar": surface, "dot": surface], linked: true)
    }

    static func state(sessions: [CoreSession] = [], asks: [CoreAsk] = [], focus: CoreFocus? = nil, escalation: CoreEscalation? = nil) -> CoreState {
        CoreState(generation: 1, now: now.timeIntervalSince1970, sessions: sessions, asks: asks, focus: focus, escalation: escalation)
    }

    static let codex = CoreSession(id: "codex:1", provider: "codex", label: "sidepulse-core", mode: "waiting", lifecycle: "active",
                                   nextActor: "user", since: now.timeIntervalSince1970 - 45,
                                   ask: CoreAsk(kind: "permission", openedAt: now.timeIntervalSince1970 - 45, summary: "Run: rm -rf build"))
    static let claude = CoreSession(id: "claude:1", provider: "claude", label: "jr-bar-b7", mode: "tool_running", lifecycle: "active",
                                    since: now.timeIntervalSince1970 - 600)
    static let gemini = CoreSession(id: "gemini:1", provider: "gemini", label: "docs-sweep", mode: "idle", lifecycle: "completed",
                                    since: now.timeIntervalSince1970 - 100, updatedAt: now.timeIntervalSince1970 - 12)

    @Test("an ask reads as an amber pulse naming the session, kind and wait")
    func ask() throws {
        let state = Self.state(sessions: [Self.codex, Self.claude], asks: [CoreAsk(session: "codex:1", kind: "permission", openedAt: Self.now.timeIntervalSince1970 - 45, summary: "Run: rm -rf build")])
        let explanation = try #require(LightExplainer.explain(lights: Self.lights(why: "needs_you"), state: state, settings: nil, now: Self.now))
        #expect(explanation.motion == "Amber pulse")
        #expect(explanation.reason == "Codex sidepulse-core is waiting on you (permission, 45 s)")
        #expect(explanation.headline == "Amber pulse: Codex sidepulse-core is waiting on you (permission, 45 s)")
        #expect(explanation.session == "codex:1")
    }

    @Test("working derives the motion word from the surface and names the worker")
    func working() throws {
        let state = Self.state(sessions: [Self.claude])
        let lights = Self.lights(why: "working", motion: "breathe", fallback: "#2B8FFF")
        let explanation = try #require(LightExplainer.explain(lights: lights, state: state, settings: nil, now: Self.now))
        #expect(explanation.motion == "Breathing blue")
        #expect(explanation.reason == "Claude jr-bar-b7 is working")
        #expect(explanation.session == "claude:1")
        let relay = try #require(LightExplainer.explain(lights: Self.lights(why: "working", motion: "chase", fallback: "#00E5FF"), state: state, settings: nil, now: Self.now))
        #expect(relay.motion == "Cyan relay")
    }

    @Test("a long-task or unknown-mode live row still explains a working light")
    func longTaskProgressIsWorking() throws {
        // `long_task_progress` used to fall off the mode list here while
        // the daemon counted it active — the explainer named nobody. The
        // filter now goes through SessionActivity.reduce, the same read
        // the panel makes.
        let longTask = CoreSession(id: "claude:lt", provider: "claude", label: "big-build",
                                   mode: "long_task_progress", lifecycle: "active",
                                   since: Self.now.timeIntervalSince1970 - 1200)
        let future = CoreSession(id: "codex:fm", provider: "codex", label: "deploy",
                                 mode: "some_future_mode", lifecycle: "active",
                                 since: Self.now.timeIntervalSince1970 - 60)
        let state = Self.state(sessions: [longTask, future])
        let explanation = try #require(LightExplainer.explain(
            lights: Self.lights(why: "working", motion: "breathe", fallback: "#00E5FF"),
            state: state, settings: nil, now: Self.now))
        // The most recently started worker leads, and the other counts.
        #expect(explanation.session == "codex:fm")
        #expect(explanation.reason == "Codex deploy is working and 1 more")
    }

    @Test("a completion says who finished and how long ago")
    func completed() throws {
        let state = Self.state(sessions: [Self.gemini, Self.claude])
        let explanation = try #require(LightExplainer.explain(lights: Self.lights(why: "completed_unseen"), state: state, settings: nil, now: Self.now))
        #expect(explanation.motion == "Green sweep")
        #expect(explanation.reason == "Gemini docs-sweep finished 12 s ago")
        #expect(explanation.session == "gemini:1")
    }

    @Test("quiet hours name the schedule end")
    func quiet() throws {
        let until = Self.now.timeIntervalSince1970 + 3600
        let state = Self.state(focus: CoreFocus(mode: "dark", source: "schedule", until: until))
        let explanation = try #require(LightExplainer.explain(lights: Self.lights(why: "quiet", motion: "static", fallback: "#1D050A"), state: state, settings: nil, now: Self.now))
        #expect(explanation.motion == "Dim ember")
        #expect(explanation.reason == "Quiet hours until \(LightExplainer.clock(until))")
        #expect(explanation.session == nil)
    }

    @Test("idle, failed and unknown whys all produce a line")
    func others() throws {
        let idle = try #require(LightExplainer.explain(lights: Self.lights(why: "idle", motion: "breathe", fallback: "#020204"), state: Self.state(), settings: nil, now: Self.now))
        #expect(idle.headline == "Idle breath: Nothing is running")
        var failed = Self.gemini
        failed.lifecycle = "failed"
        let failure = try #require(LightExplainer.explain(lights: Self.lights(why: "failed"), state: Self.state(sessions: [failed]), settings: nil, now: Self.now))
        #expect(failure.headline == "Red flash: Gemini docs-sweep failed 12 s ago")
        let unknown = try #require(LightExplainer.explain(lights: Self.lights(why: "Moon-Phase", motion: "sweep", fallback: "#AF52DE"), state: Self.state(), settings: nil, now: Self.now))
        #expect(unknown.why == "moon_phase")
        #expect(unknown.motion == "Purple sweep")
        #expect(unknown.reason == "Core says Moon-Phase")
        #expect(LightExplainer.explain(lights: nil, state: nil, settings: nil) == nil)
        #expect(LightExplainer.explain(lights: CoreLights(), state: nil, settings: nil) == nil)
    }

    @Test("the details list every surface and the brightness settings")
    func details() throws {
        let document = SettingsDocument(.object([
            "global_brightness_scale": .number(0.8), "idle_dim_enabled": .bool(true), "idle_dim_after_minutes": .number(10),
            "idle_dim_fraction": .number(0.3), "dnd_schedule_enabled": .bool(true), "dnd_schedule_start_minutes": .number(1320),
            "dnd_schedule_end_minutes": .number(420), "dnd_schedule_mode": .string("dark"),
        ]))
        let explanation = try #require(LightExplainer.explain(lights: Self.lights(why: "idle"), state: Self.state(), settings: document, now: Self.now))
        let labels = explanation.details.map(\.label)
        #expect(labels == ["Hardware", "Screen Bar", "Dot", "Dot role", "Screen Bar link", "Global brightness", "Idle dim", "Quiet hours"])
        // The role decides the Dot's program and its `why`, so the popover
        // names it; a frame with no `role` means the Dot drives itself.
        #expect(explanation.details.first { $0.label == "Dot role" }?.value == "Status · its own display")
        var driven = Self.lights(why: "idle")
        driven.surfaces["dot"]?.role = "asks"
        let beacon = try #require(LightExplainer.explain(lights: driven, state: Self.state(), settings: document, now: Self.now))
        #expect(beacon.details.first { $0.label == "Dot role" }?.value == "Ask beacon")
        #expect(explanation.details.first?.value == "8 LEDs · beat · red · 79% bright · started 12 s ago")
        #expect(explanation.details.first { $0.label == "Global brightness" }?.value == "80%")
        #expect(explanation.details.first { $0.label == "Idle dim" }?.value == "to 30% after 10 min")
        #expect(explanation.details.first { $0.label == "Quiet hours" }?.value == "dark 22:00–07:00")
    }

    @Test("the two links are named separately, and only claimed when real")
    func linkLines() throws {
        // `lights.linked` is the Screen Bar following the strip and needs
        // both surfaces in the frame; `dot_link.state` is the Pro + Dot
        // pair written as one unit. One flag must never stand in for the
        // other.
        var linked = Self.lights(why: "idle")
        linked.dotLink = CoreDotLink(state: "linked", role: "extend")
        let both = try #require(LightExplainer.explain(lights: linked, state: Self.state(), settings: nil, now: Self.now))
        #expect(both.details.first { $0.label == "Screen Bar link" }?.value == "plays the strip's program")
        #expect(both.details.first { $0.label == "Pro + Dot link" }?.value == "written as one unit")

        // linked: true with no screen_bar surface claims nothing, and a
        // daemon that sends no dot_link never gets a Pro + Dot line.
        var barless = Self.lights(why: "idle")
        barless.surfaces.removeValue(forKey: "screen_bar")
        let none = try #require(LightExplainer.explain(lights: barless, state: Self.state(), settings: nil, now: Self.now))
        #expect(none.details.contains { $0.label == "Screen Bar link" } == false)
        #expect(none.details.contains { $0.label == "Pro + Dot link" } == false)
    }

    @Test("colour names follow the hue")
    func colours() {
        #expect(LightExplainer.colourName("#FF3A00") == "red")
        #expect(LightExplainer.colourName("#FF9500") == "orange")
        #expect(LightExplainer.colourName("#FFCC00") == "amber")
        #expect(LightExplainer.colourName("#00FF66") == "green")
        #expect(LightExplainer.colourName("#00E5FF") == "cyan")
        #expect(LightExplainer.colourName("#2B8FFF") == "blue")
        #expect(LightExplainer.colourName("#AF52DE") == "purple")
        #expect(LightExplainer.colourName("#020204") == "dim")
        #expect(LightExplainer.colourName("#FFFFFF") == "white")
        #expect(LightExplainer.colourName("off") == "off")
        #expect(LightExplainer.colourName("nope") == nil)
    }

    @Test("a seconds_in_state that is really an epoch is not printed as a duration")
    func implausibleDurations() {
        #expect(LightExplainer.elapsed(seconds: 0) == "0 s")
        #expect(LightExplainer.elapsed(seconds: 45) == "45 s")
        #expect(LightExplainer.elapsed(seconds: 3 * 3600) == "3 h")
        #expect(LightExplainer.elapsed(seconds: 5 * 86400) == "5 d")
        #expect(LightExplainer.elapsed(seconds: -1) == nil)
        // What the daemon actually sent on 2026-09-10: an epoch, which
        // would have read "20704 d" in the popover and in the headline.
        #expect(LightExplainer.elapsed(seconds: 1_788_870_132.6) == nil)
        #expect(LightExplainer.elapsed(seconds: .infinity) == nil)
        #expect(LightExplainer.elapsed(seconds: .nan) == nil)
    }
}
