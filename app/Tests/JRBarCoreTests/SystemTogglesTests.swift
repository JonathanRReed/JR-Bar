import Testing
@testable import JRBarCore

/// The Control Center strip's pure half: which command a flip runs,
/// what a defaults read maps to on, and which cases are verbs not
/// states. The process layer is thin — every decision lives here.
@Suite struct SystemTogglesTests {

    // MARK: - Shape

    @Test func theSetIsEightAndStable() {
        #expect(SystemToggle.allCases.count == 8)
        // Raw values persist in defaults — they must never drift.
        #expect(SystemToggle.keepAwake.rawValue == "keepAwake")
        #expect(SystemToggle.dockAutoHide.rawValue == "dockAutoHide")
    }

    @Test func verbsAreMomentaryStatesAreToggles() {
        #expect(SystemToggle.lock.isMomentary)
        #expect(SystemToggle.screenSaver.isMomentary)
        for toggle in [SystemToggle.keepAwake, .darkMode, .desktopIcons,
                       .hiddenFiles, .mute, .dockAutoHide] {
            #expect(!toggle.isMomentary)
        }
    }

    // MARK: - Commands

    @Test func darkModeRidesAppleScriptNotPrivateCalls() {
        let on = SystemToggle.darkMode.applyCommand(on: true)
        #expect(on?.contains("appearance preferences") == true)
        #expect(on?.contains("dark mode to true") == true)
        #expect(on?.contains("SLSSet") == false, "no private SkyLight call")
        #expect(SystemToggle.darkMode.applyCommand(on: false)?.contains("to false") == true)
    }

    @Test func finderWritesRestartFinder() {
        for toggle in [SystemToggle.desktopIcons, .hiddenFiles] {
            let cmd = toggle.applyCommand(on: false)
            #expect(cmd?.contains("defaults write com.apple.finder") == true)
            #expect(cmd?.contains("killall Finder") == true)
            #expect(toggle.restarts == "Finder")
        }
        #expect(SystemToggle.desktopIcons.applyCommand(on: true)?
            .contains("CreateDesktop -bool true") == true)
        #expect(SystemToggle.hiddenFiles.applyCommand(on: true)?
            .contains("AppleShowAllFiles -bool true") == true)
    }

    @Test func dockAutohideWritesAndRestarts() {
        let cmd = SystemToggle.dockAutoHide.applyCommand(on: true)
        #expect(cmd?.contains("com.apple.dock autohide -bool true") == true)
        #expect(cmd?.contains("killall Dock") == true)
    }

    @Test func theDockFlipsLiveBeforeItEverRestarts() {
        // System Events sets the running Dock in place; the killall
        // path is the last resort only, so the chip no longer promises
        // a restart.
        let live = SystemToggle.dockAutoHide.liveApplyCommand(on: false)
        #expect(live?.contains("dock preferences to set autohide to false") == true)
        #expect(live?.contains("killall") == false)
        #expect(SystemToggle.dockAutoHide.restarts == nil)
        // Every other toggle's live path is its ordinary command.
        #expect(SystemToggle.hiddenFiles.liveApplyCommand(on: true)
                == SystemToggle.hiddenFiles.applyCommand(on: true))
    }

    // MARK: - The strip

    @Test func aFreshStripIsTheOriginalEight() {
        #expect(SystemToggle.defaultStrip == [.keepAwake, .darkMode, .desktopIcons, .hiddenFiles,
                                              .mute, .screenSaver, .lock, .dockAutoHide])
    }

    @Test func aStoredStripKeepsCanonicalOrderAndDropsTheUnknown() {
        #expect(SystemToggle.strip(fromStored: ["lock", "darkMode", "warpDrive", "lock"])
                == [.darkMode, .lock])
        // Hiding every chip is a choice, not a reset.
        #expect(SystemToggle.strip(fromStored: []).isEmpty)
    }

    @Test func lockIsThePublicDisplaySleep() {
        // CGSession is gone on macOS 27 — display sleep is the honest
        // verb (locks on wake where a password is required).
        let cmd = SystemToggle.lock.applyCommand(on: true)
        #expect(cmd?.contains("displaysleepnow") == true)
        #expect(cmd?.contains("SACLock") == false, "no private login call")
    }

    @Test func inProcessTogglesYieldNoShell() {
        // IOPMAssertion and CoreAudio apply in-process — a shell
        // command for them would be a lie about the mechanism.
        #expect(SystemToggle.keepAwake.applyCommand(on: true) == nil)
        #expect(SystemToggle.mute.applyCommand(on: true) == nil)
    }

    // MARK: - Read mapping

    @Test func absentReadsAsTheDeclaredDefault() {
        // Finder shows the desktop when the key is absent; autohide
        // and hidden-files default off.
        #expect(SystemToggle.readMaps(nil, onWhenAbsent: true) == true)
        #expect(SystemToggle.readMaps(nil, onWhenAbsent: false) == false)
    }

    @Test func defaultsOutputMapsHonestly() {
        #expect(SystemToggle.readMaps("1", onWhenAbsent: false) == true)
        #expect(SystemToggle.readMaps("0", onWhenAbsent: true) == false)
        #expect(SystemToggle.readMaps("true", onWhenAbsent: false) == true)
        #expect(SystemToggle.readMaps("false\n", onWhenAbsent: true) == false)
        // A surprise value reads as off — never as a guess of "on".
        #expect(SystemToggle.readMaps("banana", onWhenAbsent: true) == false)
    }

    @Test func probesCoverTheDefaultsBackedToggles() {
        #expect(SystemToggle.desktopIcons.defaultsProbe?.key == "CreateDesktop")
        #expect(SystemToggle.desktopIcons.defaultsProbe?.onWhenAbsent == true)
        #expect(SystemToggle.hiddenFiles.defaultsProbe?.key == "AppleShowAllFiles")
        #expect(SystemToggle.dockAutoHide.defaultsProbe?.domain == "com.apple.dock")
        // The in-process toggles and the verbs declare no plist probe.
        #expect(SystemToggle.keepAwake.defaultsProbe == nil)
        #expect(SystemToggle.lock.defaultsProbe == nil)
    }
}
