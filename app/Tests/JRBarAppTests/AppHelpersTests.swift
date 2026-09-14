import AppKit
import Testing
import JRBarCore
import JRBarLEDS
import JRBarUI
@testable import JRBarApp

/// The panel row's pure text helpers: the cwd tail, the bounded "fact"
/// snippets, the hook's last word about a working session, the snooze
/// clock, and the composed tooltip.
@Suite struct SessionRowTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func row(_ session: CoreSession) -> SessionRow {
        SessionRow(session: session, pinnedAsk: nil)
    }

    @Test func tailCollapsesHomeAndKeepsTheLastTwoComponents() {
        #expect(SessionRow.tail(of: NSHomeDirectory()) == "~")
        #expect(SessionRow.tail(of: NSHomeDirectory() + "/Downloads/JR-Bar/src") == "JR-Bar/src")
        #expect(SessionRow.tail(of: "/opt/a/b/c/d") == "c/d")
        #expect(SessionRow.tail(of: "/tmp") == "/tmp")
        #expect(SessionRow.tail(of: "a/b/c") == "b/c")
    }

    @Test func shortFactCollapsesWhitespaceAndBoundsTheLength() {
        #expect(SessionRow.shortFact(nil) == nil)
        #expect(SessionRow.shortFact("   \n  ") == nil)
        #expect(SessionRow.shortFact("a  b\n c") == "a b c")
        #expect(SessionRow.shortFact("short") == "short")
        let long = SessionRow.shortFact(String(repeating: "x", count: 40))
        #expect(long?.hasSuffix("…") == true)
        #expect(long?.count == 24)
    }

    @Test func activityFactSpeaksOnlyForWorkingRows() {
        let working = CoreSession(id: "s1", provider: "claude", mode: "working", lifecycle: "active",
                                  event: "PreToolUse", tool: "Bash")
        #expect(SessionRow.activityFact(session: working, activity: .working) == "running Bash")
        let done = CoreSession(id: "s2", provider: "claude", mode: "working", lifecycle: "active",
                               event: "PostToolUse", tool: "Edit")
        #expect(SessionRow.activityFact(session: done, activity: .working) == "ran Edit")
        let compacting = CoreSession(id: "s3", provider: "claude", mode: "working", lifecycle: "active",
                                     event: "PreCompact")
        #expect(SessionRow.activityFact(session: compacting, activity: .working) == "compacting")
        // A stale row's last event is history, not a current fact.
        let stale = CoreSession(id: "s4", provider: "claude", mode: "working", lifecycle: "active",
                                stale: true, event: "PreToolUse", tool: "Bash")
        #expect(SessionRow.activityFact(session: stale, activity: .working) == nil)
        // And a waiting row's fact is the ask, not the last event.
        #expect(SessionRow.activityFact(session: working, activity: .waiting) == nil)
    }

    @Test func isSnoozedFollowsTheExpiry() {
        let future = Self.row(CoreSession(id: "s", provider: "claude",
                                          snoozedUntil: Self.now.timeIntervalSince1970 + 60))
        #expect(future.isSnoozed(now: Self.now))
        let past = Self.row(CoreSession(id: "s", provider: "claude",
                                        snoozedUntil: Self.now.timeIntervalSince1970 - 60))
        #expect(!past.isSnoozed(now: Self.now))
        let none = Self.row(CoreSession(id: "s", provider: "claude"))
        #expect(!none.isSnoozed(now: Self.now))
    }

    @Test func helpComposesTheFactsItHas() {
        // Nothing honest to say → no tooltip at all.
        let quiet = Self.row(CoreSession(id: "s1", provider: "claude", mode: "idle", lifecycle: "active"))
        #expect(quiet.help(now: Self.now) == nil)

        let placed = Self.row(CoreSession(id: "s2", provider: "claude", cwd: "/work/project",
                                          mode: "idle", lifecycle: "active"))
        #expect(placed.help(now: Self.now)?.contains("/work/project") == true)

        let snoozed = Self.row(CoreSession(id: "s3", provider: "claude", mode: "idle", lifecycle: "active",
                                           snoozedUntil: Self.now.timeIntervalSince1970 + 3600))
        #expect(snoozed.help(now: Self.now)?.contains("Snoozed until") == true)

        let remote = Self.row(CoreSession(id: "remote:studio-mac:claude:abc", provider: "claude",
                                          mode: "idle", lifecycle: "active"))
        #expect(remote.help(now: Self.now)?.contains("Runs on studio-mac") == true)

        let ended = Self.row(CoreSession(id: "s5", provider: "claude", lifecycle: "ended"))
        #expect(ended.help(now: Self.now)?.contains("Went away without confirming") == true)

        // A working row silent past quietAfter says so without crying stale.
        let silent = Self.row(CoreSession(id: "s6", provider: "claude", mode: "working", lifecycle: "active",
                                          since: Self.now.timeIntervalSince1970 - 31 * 60))
        #expect(silent.help(now: Self.now)?.contains("last signal was") == true)
    }
}

/// The status item's pure redraw plan: which spec each style draws,
/// which style may carry a label, and who owns the item's width.
@Suite struct StatusItemPlanTests {
    static let meters = [StatusMeter(id: "claude", name: "Claude", glyph: .symbol("asterisk"), fraction: 0.8)]
    static let dots = [SessionDot(id: "a", state: .working), SessionDot(id: "b", state: .ask)]

    @Test func agentsStyleIsAStripCarryingTheSessionDots() {
        let plan = StatusItemController.plan(style: .agents, sessionDots: Self.dots)
        #expect(plan.spec.sessions == Self.dots)
        #expect(plan.isStrip)
        // 2 + 14 + 4 + 2×6 + 3 + 2 = 47 → ceil; the renderer's own number.
        #expect(plan.stripWidth == StatusIconRenderer.size(for: plan.spec).width)
        #expect(plan.stripWidth! > StatusIconRenderer.size.width)
        #expect(plan.label == nil)
    }

    @Test func anEmptyAgentsStripStillOwnsItsWidth() {
        // The last session ending must shrink the item back — even an
        // empty strip gets its (square) width.
        let plan = StatusItemController.plan(style: .agents)
        #expect(plan.isStrip)
        #expect(plan.stripWidth == StatusIconRenderer.size.width)
    }

    @Test func metersStyleCarriesTheMetersAndTheStateDot() {
        let plan = StatusItemController.plan(style: .meters, meters: Self.meters, dotState: .working)
        #expect(plan.spec.meters == Self.meters)
        #expect(plan.spec.dot == .working)
        #expect(plan.isStrip)
    }

    @Test func thePulseTurnsTheDotAmberButNeverAFailure() {
        let pulsing = StatusItemController.plan(style: .meters, isPulsing: true, dotState: .working)
        #expect(pulsing.spec.dot == .ask)
        let failed = StatusItemController.plan(style: .meters, isPulsing: true, dotState: .error)
        #expect(failed.spec.dot == .error)
    }

    @Test func squareStylesOwnNoWidthAndCarryNoStrip() {
        let plan = StatusItemController.plan(style: .glyph, meters: Self.meters, meterOverflow: 2,
                                             dotState: .error, sessionDots: Self.dots, labelText: "2 working")
        #expect(!plan.isStrip)
        #expect(plan.stripWidth == nil)
        #expect(plan.spec.meters.isEmpty)
        #expect(plan.spec.sessions.isEmpty)
        #expect(plan.spec.overflow == 0)
        #expect(plan.spec.dot == .idle)
        #expect(plan.label == nil)
    }

    @Test func onlyTheRingStyleTakesTheRingFraction() {
        #expect(StatusItemController.plan(style: .glyphRing, ringFraction: 0.42).spec.ringFraction == 0.42)
        #expect(StatusItemController.plan(style: .glyph, ringFraction: 0.42).spec.ringFraction == nil)
        #expect(StatusItemController.plan(style: .agents, ringFraction: 0.42).spec.ringFraction == nil)
    }

    @Test func onlyTheLabelStyleShowsALabel() {
        #expect(StatusItemController.plan(style: .glyphLabel, labelText: "2 working").label == "2 working")
        #expect(StatusItemController.plan(style: .agents, labelText: "2 working").label == nil)
        #expect(StatusItemController.plan(style: .glyphLabel).label == nil)
    }

    @Test func theTintReachesTheSpecAsHex() {
        let plan = StatusItemController.plan(style: .glyph, tint: .systemOrange)
        #expect(plan.spec.tintHex != nil)
        #expect(StatusItemController.plan(style: .glyph).spec.tintHex == nil)
    }

    @Test func onlyTheOrbitStyleCarriesTheDeviceReading() {
        let device = StatusDeviceInfo(wifiDots: 3, wifiRSSI: -58,
                                      batteryPercent: 72, hasBattery: true)
        let orbit = StatusItemController.plan(style: .orbit, device: device)
        #expect(orbit.isStrip, "the roundel owns its own width")
        #expect(orbit.spec.device == device)
        #expect(orbit.stripWidth == StatusIconRenderer.orbitSize.width)
        #expect(orbit.label == nil)
        // Other styles never take it — a device spec on a glyph would be
        // a stray reading the picture can't show.
        #expect(StatusItemController.plan(style: .glyph, device: device).spec.device == nil)
        #expect(StatusItemController.plan(style: .agents, device: device).spec.device == nil)
    }
}

/// The `orbit` icon's Wi-Fi read: the dBm-to-dots bucketing, off-device.
@Suite struct StatusDeviceMonitorTests {
    @Test func rssiBuckets() {
        #expect(StatusDeviceMonitor.wifiDots(rssi: -40) == 4)
        #expect(StatusDeviceMonitor.wifiDots(rssi: -55) == 4)
        #expect(StatusDeviceMonitor.wifiDots(rssi: -60) == 3)
        #expect(StatusDeviceMonitor.wifiDots(rssi: -70) == 2)
        #expect(StatusDeviceMonitor.wifiDots(rssi: -80) == 1)
        #expect(StatusDeviceMonitor.wifiDots(rssi: -95) == 1, "a thread of a link is still a dot")
    }
}

/// The Screen Bar's program acceptance: a safe program is installed, a
/// refused one keeps the previous program and explains itself.
@Suite struct ScreenBarProgramTests {
    @Test func aValidProgramIsAccepted() {
        let decision = ScreenBarController.programDecision("off", fallback: "off")
        #expect(decision.program != nil)
        #expect(decision.programText == "off")
        #expect(decision.rejection == nil)
    }

    @Test func aClampedProgramIsAcceptedTransformed() {
        // A 100 ms loop is faster than the 2 Hz floor: the compiler
        // lengthens it, the band still plays it.
        let text = "#ff0000 50ms none\n#000000 50ms none\nrepeat"
        let decision = ScreenBarController.programDecision(text, fallback: "off")
        #expect(decision.program != nil)
        #expect(decision.rejection == nil)
        #expect(decision.programText != nil && decision.programText != text)
    }

    @Test func anUnparseableProgramIsRefusedWithItsParseError() {
        let decision = ScreenBarController.programDecision("#fff", fallback: "off")
        #expect(decision.program == nil)
        #expect(decision.rejection != nil && !decision.rejection!.isEmpty)
    }

    @Test func anEditorViolationIsRefusedWithTheCompilerReason() {
        // Parses, but a zero-duration roll is not a program the daemon
        // would write: the compiler's own word is the rejection.
        let decision = ScreenBarController.programDecision("roll-left 0s", fallback: "off")
        #expect(decision.program == nil)
        #expect(decision.rejection == "invalid_program")
    }
}

/// The Apply sheet's layer planning and the aux bindings' full-replacement
/// payload, including the analog sectors while `analog_enabled` is on.
@Suite struct DeckStorePlanningTests {
    @Test func applyTargetsAreTheSelectedProfileLayers() {
        let layers = [DeckKeymapLayer(profile: 0, layer: 0), DeckKeymapLayer(profile: 0, layer: 1),
                      DeckKeymapLayer(profile: 1, layer: 0)]
        let targets = DeckStore.applyTargets(layers: layers, selected: DeckKeymapLayer(profile: 0, layer: 1),
                                             deviceProfile: 0)
        #expect(targets.map(\.id) == ["0/0", "0/1"])
    }

    @Test func applyTargetsFallsBackToTheSelectionAlone() {
        // A daemon that reports no layers gets the one the sheet picked.
        let selected = DeckKeymapLayer(profile: 1, layer: 2)
        #expect(DeckStore.applyTargets(layers: [], selected: selected, deviceProfile: 0).map(\.id) == ["1/2"])
        // No selection at all: the device's own profile, layer 0.
        #expect(DeckStore.applyTargets(layers: [], selected: nil, deviceProfile: 3).map(\.id) == ["3/0"])
        #expect(DeckStore.applyTargets(layers: [], selected: nil, deviceProfile: nil).map(\.id) == ["0/0"])
    }

    @Test func applyScopePrefersTheSheetsChoice() {
        let row = DeckKeymapLayer(profile: 0, layer: 0, scope: "claude")
        #expect(DeckStore.applyScope(["0/0": "codex"], for: row) == "codex")
        #expect(DeckStore.applyScope([:], for: row) == "claude")
        // No stored scope and none on the row: every provider.
        #expect(DeckStore.applyScope([:], for: DeckKeymapLayer(profile: 0, layer: 0)) == "automatic")
        #expect(DeckStore.applyScope([:], for: DeckKeymapLayer(profile: 0, layer: 0, scope: "")) == "automatic")
    }

    @Test func analogControlsFollowTheAnalogSwitch() {
        #expect(DeckStore.analogControls(in: nil).isEmpty)
        #expect(DeckStore.analogControls(in: DeckState(settings: DeckSettings())).isEmpty)

        let on = DeckState(settings: DeckSettings(analogEnabled: true))
        let controls = DeckStore.analogControls(in: on)
        #expect(controls.map(\.index) == [20, 21, 22, 23])
        #expect(controls.allSatisfy { $0.mapping == nil })
    }

    @Test func analogMappingsComeFromTheBindings() {
        let deck = DeckState(
            aux: [DeckAuxControl(index: 22, label: "x", mapping: "open_usage"),
                  DeckAuxControl(index: 23, label: "y", mapping: "next_bank")],
            settings: DeckSettings(analogEnabled: true, bindings: [
                DeckBinding(index: 20, action: "reveal_current_ask"),
                // An explicit unbind wins over the daemon's default.
                DeckBinding(index: 22, action: nil),
            ]))
        let controls = DeckStore.analogControls(in: deck)
        #expect(controls.first { $0.index == 20 }?.mapping == "reveal_current_ask")
        #expect(controls.first { $0.index == 21 }?.mapping == nil)
        #expect(controls.first { $0.index == 22 }?.mapping == nil)
        // An aux-carried default survives where no binding says otherwise.
        #expect(controls.first { $0.index == 23 }?.mapping == "next_bank")
    }

    @Test func auxBindingsReplacesTheWholeSetIncludingAnalog() {
        let controls = [DeckAuxControl(index: 13, label: "e1", mapping: "next_bank"),
                        DeckAuxControl(index: 14, label: "e2")]
        let analog = [DeckAuxControl(index: 20, label: "a1", mapping: "open_usage")]
        let payload = DeckStore.auxBindings(controls: controls, analog: analog,
                                            changing: 14, to: "open_usage")
        #expect(payload.map(\.index) == [13, 14, 20])
        #expect(payload.first { $0.index == 13 }?.action == "next_bank")
        #expect(payload.first { $0.index == 14 }?.action == "open_usage")
        #expect(payload.first { $0.index == 20 }?.action == "open_usage")
    }

    @Test func auxBindingsCanUnbind() {
        let controls = [DeckAuxControl(index: 13, label: "e1", mapping: "next_bank")]
        let payload = DeckStore.auxBindings(controls: controls, analog: [], changing: 13, to: nil)
        #expect(payload.count == 1)
        #expect(payload.first?.index == 13)
        #expect(payload.first?.action == nil)
    }
}

/// The card's featured window: the daemon's constrained pick when it
/// names one (least headroom of the applicable measured lanes), else the
/// 5h convention (S6.4).
@Suite @MainActor struct FeaturedWindowTests {
    static func provider(_ constrained: CoreConstrainedLane?) -> CoreProviderUsage {
        CoreProviderUsage(id: "claude", windows: [
            CoreUsageWindow(key: "five_hour", name: "5h", usedPct: 42),
            CoreUsageWindow(key: "seven_day", name: "7d", usedPct: 61),
        ], constrained: constrained)
    }

    @Test func constrainedPickLeadsOverTheConvention() {
        let provider = Self.provider(CoreConstrainedLane(id: "seven_day", name: "7d", usedPct: 61,
                                                         reason: "least_headroom", candidates: 2))
        #expect(UsageCenterStore.featuredWindow(of: provider)?.id == "seven_day")
        #expect(UsageCenterStore.primaryWindow(of: provider)?.id == "five_hour")
        #expect(provider.constrained?.explanation == "least headroom of 2 measured windows")
    }

    @Test func conventionLeadsWhenTheDaemonNamesNothing() {
        let provider = Self.provider(nil)
        #expect(UsageCenterStore.featuredWindow(of: provider)?.id == "five_hour")
        // A constrained id that matches no window falls back the same way.
        let stale = Self.provider(CoreConstrainedLane(id: "gone", name: "gone"))
        #expect(UsageCenterStore.featuredWindow(of: stale)?.id == "five_hour")
    }
}
