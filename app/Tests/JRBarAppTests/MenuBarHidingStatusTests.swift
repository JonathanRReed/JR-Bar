import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// The page's one answer to "is hiding working, and if not, why" — and
/// the guarantee behind it: Show everything and turning the utility off
/// always give every item back.
@Suite("Menu Bar — hiding status and the way out")
struct MenuBarHidingStatusTests {
    private func assess(_ edit: (inout MenuBarHidingStatus.Inputs) -> Void) -> MenuBarHidingStatus {
        var inputs = MenuBarHidingStatus.Inputs()
        inputs.engine = .divider
        inputs.dividerHidden = 3
        inputs.recovery = .clear
        edit(&inputs)
        return MenuBarHidingStatus.assess(inputs)
    }

    // MARK: The lines

    @Test("a healthy bar says how many items sit left of the icon and how to bring them back")
    func healthy() {
        let status = assess { _ in }
        #expect(status.tone == .ok)
        #expect(status.headline == "Hiding 3 items left of the icon")
        #expect(status.detail.contains("Click the icon"))
        #expect(status.fix == nil)
        #expect(status.offersShowEverything)
        let single = assess { $0.dividerHidden = 1 }
        #expect(single.headline == "Hiding 1 item left of the icon")
    }

    @Test("a reveal does not claim the planned hidden items are hidden")
    func revealed() {
        let status = assess { $0.revealed = true }
        #expect(status.tone == .note)
        #expect(status.headline == "Showing the hidden section")
        #expect(status.detail.contains("⌘-drag one right of the JR-Bar icon"))
        #expect(status.offersShowEverything)
    }

    @Test("missing evidence and pending recovery never produce a green hiding claim")
    func checking() {
        var inputs = MenuBarHidingStatus.Inputs()
        inputs.dividerHidden = 3
        #expect(MenuBarHidingStatus.assess(inputs).headline == "Enabled, hiding has not been checked")
        for recovery in [MenuBarWakeRecovery.Verdict.idle, .settling, .reseated(.spacerNotStanding)] {
            let status = assess { $0.recovery = recovery }
            #expect(status.tone == .note)
            #expect(!status.headline.hasPrefix("Hiding "))
            #expect(status.offersShowEverything)
            if case .reseated = recovery {
                #expect(status.detail == MenuBarWakeRecovery.line(for: recovery))
            }
        }
        let empty = assess { $0.recovery = .idle; $0.dividerHidden = 0; $0.iconLeftmost = true }
        #expect(empty.detail.contains("Hold ⌘ and drag the icon right"))
        let misplaced = assess { $0.recovery = .idle; $0.dividerHidden = 0 }
        #expect(misplaced.detail.contains("Hold ⌘ and drag an item left of the JR-Bar icon"))
    }

    @Test("unverified or stuck recovery reaches the banner with its existing explanation")
    func recoveryWarnings() {
        for recovery in [MenuBarWakeRecovery.Verdict.unverified, .stuck(.offRow),
                         .stuck(.spacerNotStanding), .stuck(.overlapped(["Clock"]))] {
            let status = assess { $0.recovery = recovery }
            #expect(status.tone == .warning)
            #expect(status.detail == MenuBarWakeRecovery.line(for: recovery))
            #expect(status.offersShowEverything)
            #expect(status.fix == nil)
        }
    }

    @Test("only a clear or recovered divider can report the planned count as hiding")
    func verified() {
        for recovery in [MenuBarWakeRecovery.Verdict.clear, .recovered(.spacerNotStanding)] {
            let status = assess { $0.recovery = recovery }
            #expect(status.tone == .ok)
            #expect(status.headline == "Hiding 3 items left of the icon")
        }
    }

    @Test("off, another provider and standing overlays retain precedence over live divider status")
    func liveStatePrecedence() {
        for recovery in [MenuBarWakeRecovery.Verdict.idle, .settling, .unverified, .stuck(.offRow)] {
            let off = assess { $0.recovery = recovery; $0.revealed = true; $0.enabled = false }
            #expect(off.headline == "Menu Bar is off")
            let provider = assess {
                $0.recovery = recovery; $0.revealed = true
                $0.externalProvider = "Ice"; $0.externalProviderRunning = true
                $0.overlay = .showEverything
            }
            #expect(provider.headline == "Ice is hiding the bar")
            let shown = assess { $0.recovery = recovery; $0.revealed = true; $0.overlay = .showEverything }
            #expect(shown.headline == "Showing everything")
            #expect(shown.fix == .restoreBar)
            let hidden = assess { $0.recovery = recovery; $0.revealed = true; $0.overlay = .hideEverything }
            #expect(hidden.headline == "Everything is tucked away")
            #expect(hidden.fix == .showEverything)
        }
    }

    @Test("a verified empty side keeps its positioning guide, while a stuck divider takes precedence")
    func emptySideRecovery() {
        let verified = assess { $0.dividerHidden = 0; $0.iconLeftmost = true }
        #expect(verified.headline == "Nothing is hidden yet")
        #expect(verified.detail.contains("Hold ⌘ and drag the icon right"))
        let stuck = assess { $0.dividerHidden = 0; $0.recovery = .stuck(.offRow) }
        #expect(stuck.headline == "Divider needs checking")
        #expect(stuck.tone == .warning)
    }

    @Test("with nothing left of the icon the page says how to put something there, not that it is broken")
    func nothingHidden() {
        let status = assess { $0.dividerHidden = 0 }
        #expect(status.tone == .note)
        #expect(status.headline == "Nothing is hidden yet")
        #expect(!status.offersShowEverything)
    }

    @Test("off says every item shows and the picks are kept")
    func off() {
        let status = assess { $0.enabled = false }
        #expect(status.headline == "Menu Bar is off")
        #expect(status.detail.contains("Every item shows"))
        #expect(status.fix == nil)
    }

    @Test("another manager rendering parks ours, and an absent one is one click to open")
    func external() {
        let running = assess { $0.externalProvider = "Ice"; $0.externalProviderRunning = true }
        #expect(running.headline == "Ice is hiding the bar")
        #expect(running.fix == nil)
        let absent = assess { $0.externalProvider = "Ice"; $0.externalProviderRunning = false }
        #expect(absent.fix == .openProvider)
        #expect(absent.detail.contains("nothing is hidden"))
    }

    @Test("a standing overlay explains the bar first, and each has its own way back")
    func overlays() {
        let shown = assess { $0.overlay = .showEverything }
        #expect(shown.headline == "Showing everything")
        #expect(shown.fix == .restoreBar)
        let quiet = assess { $0.overlay = .hideEverything }
        #expect(quiet.fix == .showEverything)
        let noted = assess { $0.overlay = .showEverything; $0.overlayNote = "until 14:30" }
        #expect(noted.detail == "until 14:30")
    }

    @Test("before the first pass the page reads as starting, not as broken")
    func starting() {
        let parked = assess { $0.engine = .parked }
        #expect(parked.headline == "Starting up")
        #expect(parked.tone == .note)
    }

    @Test("a bar too full for the icon is named, with no fix to offer but the exit")
    func noRoom() {
        let status = assess { $0.noRoom = true }
        #expect(status.tone == .warning)
        #expect(status.headline == "The bar is too full for the JR-Bar icon")
        #expect(status.fix == nil)
        #expect(status.offersShowEverything)
    }

    @Test("a rival manager and a missing Accessibility grant each name their fix")
    func rivalAndAccessibility() {
        let rival = assess { $0.rivals = ["Bartender", "Ice"] }
        #expect(rival.fix == .quitRival("Bartender"))
        let access = assess { $0.accessibilityGranted = false }
        #expect(access.fix == .openAccessibility)
        // Most severe first: a rival outranks Accessibility.
        let rivalFirst = assess { $0.rivals = ["Ice"]; $0.accessibilityGranted = false }
        #expect(rivalFirst.headline.contains("Ice"))
    }

    // MARK: The way out is always there

    @Test("every warning offers a way out: it offers Show everything beside its fix")
    func warningsAlwaysHaveAnExit() {
        for engine in [MenuBarEngineHealth.parked, .divider] {
            for noRoom in [false, true] {
                for rivals in [[String](), ["Ice"]] {
                    for access in [false, true] {
                        for hidden in [0, 2] {
                            let status = assess {
                                $0.engine = engine; $0.noRoom = noRoom
                                $0.rivals = rivals; $0.accessibilityGranted = access
                                $0.dividerHidden = hidden
                            }
                            if status.tone == .warning {
                                #expect(status.offersShowEverything,
                                        "\(engine) noRoom=\(noRoom) rivals=\(rivals) access=\(access)")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Show everything on the utility

    @MainActor
    private func utility(_ settings: MenuBarSettings) -> (MenuBarUtility, Box) {
        let utility = MenuBarUtility()
        let box = Box(settings)
        utility.settings = { box.settings }
        utility.onSettingsChange = { box.settings = $0 }
        utility.hider.listingIsComplete = { true }
        utility.hider.listItems = { [] }
        utility.hider.onPlan = nil
        return (utility, box)
    }

    @MainActor
    final class Box {
        var settings: MenuBarSettings
        init(_ settings: MenuBarSettings) { self.settings = settings }
    }

    @MainActor
    @Test("either hidden section's reveal reaches the utility's banner inputs")
    func revealedSectionsReachStatus() {
        let (utility, _) = utility(MenuBarSettings(enabled: false))
        let hider = utility.hider
        hider.shuttersSuppressed = true
        hider.pointerHolds = { true }
        hider.rowRect = { CGRect(x: 0, y: 0, width: 1512, height: 33) }
        hider.edgeStore = MenuBarMemoryFitEdgeStore()
        hider.setControlLength = { _, _ in }
        // Seed the folded length so stop cancels every task without writing a new length.
        hider.restoreAll()
        defer { hider.stop() }
        var hidden = MenuBarItem(id: "H", ownerPID: 500, ownerName: "Synthetic Hidden",
                                 bounds: CGRect(x: 900, y: 4, width: 28, height: 24), title: nil, windowID: 1)
        hidden.bundleID = "synthetic.hidden"
        var alwaysHidden = MenuBarItem(id: "A", ownerPID: 500, ownerName: "Synthetic Always Hidden",
                                       bounds: CGRect(x: 860, y: 4, width: 28, height: 24), title: nil, windowID: 2)
        alwaysHidden.bundleID = "synthetic.always-hidden"
        utility.lastPlan.hidden = [hidden]
        utility.lastPlan.alwaysHidden = [alwaysHidden]
        let scenarios: [(Set<MenuBarItemSection>, Bool)] = [
            ([], false), ([.shown], false), ([.hidden], true), ([.alwaysHidden], true),
            ([.hidden, .alwaysHidden], true),
        ]
        for (sections, revealing) in scenarios {
            hider.hide()
            hider.reveal(sections)
            var inputs = utility.hidingStatusInputs
            #expect(inputs.revealed == revealing)
            #expect(inputs.dividerHidden == 2)
            // Assess a verified environment without starting the utility.
            inputs.enabled = true
            inputs.engine = .divider
            inputs.accessibilityGranted = true
            inputs.recovery = .clear
            let status = MenuBarHidingStatus.assess(inputs)
            #expect(status.tone == (revealing ? .note : .ok))
            #expect(status.headline == (revealing ? "Showing the hidden section" : "Hiding 2 items left of the icon"))
            inputs.noRoom = true
            #expect(MenuBarHidingStatus.assess(inputs).headline == "The bar is too full for the JR-Bar icon")
        }
        #expect(!utility.running)
    }

    @MainActor
    @Test("Show everything always shows everything — over a quiet bar too, where Show all restores")
    func showEverythingOverQuietBar() {
        var settings = MenuBarSettings(enabled: false, concealedApps: ["h.app": .hidden])
        settings.curation.overlay = MenuBarOverlay(kind: .hideEverything)
        let (utility, box) = utility(settings)
        #expect(utility.activeOverlay == .hideEverything)
        utility.showEverythingNow()
        #expect(utility.activeOverlay == .showEverything)
        #expect(box.settings.concealedApps == ["h.app": .hidden], "the picks are kept")
        #expect(utility.liveSettings().concealedApps == ["h.app": .shown])
        // The pair's Show all, by contrast, hands the curated bar back.
        utility.restoreCuratedBar()
        box.settings.curation.overlay = MenuBarOverlay(kind: .hideEverything)
        utility.showAllListed()
        #expect(utility.activeOverlay == nil)
    }

    @MainActor
    @Test("a rule that takes hold later never outvotes Show everything")
    func ruleNeverOutvotesShowEverything() {
        var settings = MenuBarSettings(enabled: false, concealedApps: ["h.app": .hidden])
        settings.curation.stateRules = [MenuBarStateRule(
            id: "mic", condition: .microphoneLive, negated: false, effects: [.quietBar])]
        let (utility, box) = utility(settings)
        utility.stateRules.rules = { box.settings.curation.stateRules }
        utility.showEverythingNow()
        utility.stateRules.absorb(.micInUse(true), now: Date().addingTimeInterval(5))
        #expect(utility.activeOverlay == .showEverything)
        #expect(utility.liveSettings().concealedApps == ["h.app": .shown])
        utility.restoreCuratedBar()
        #expect(utility.activeOverlay == .hideEverything, "back on the curated bar, the rule speaks again")
    }

    @MainActor
    @Test("the banner's fixes are the person's clicks and each lands in the settings")
    func fixesLand() {
        let (utility, box) = utility(MenuBarSettings(enabled: true))
        utility.perform(.showEverything)
        #expect(utility.activeOverlay == .showEverything)
        utility.perform(.restoreBar)
        #expect(utility.activeOverlay == nil)
        utility.perform(.turnOff)
        #expect(!box.settings.enabled)
        #expect(utility.hidingStatus.headline == "Menu Bar is off")
    }

    @MainActor
    @Test("the page's status follows the settings: overlays and providers explain")
    func statusFollowsSettings() {
        var settings = MenuBarSettings(enabled: true, concealedApps: ["h.app": .hidden, "s.app": .alwaysHidden,
                                                                      "t.app": .shown])
        settings.sections = ["Weather": .hidden]
        let (utility, box) = utility(settings)
        box.settings.curation.overlay = MenuBarOverlay(kind: .showEverything)
        #expect(utility.hidingStatus.headline == "Showing everything")
        box.settings.provider = .ice
        #expect(utility.hidingStatus.headline == "Ice is hiding the bar")
    }
}
