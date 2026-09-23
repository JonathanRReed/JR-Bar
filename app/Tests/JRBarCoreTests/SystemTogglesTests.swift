import Foundation
import Testing
@testable import JRBarCore

/// The Control Center strip's pure half: which command a flip runs,
/// what a defaults read maps to on, and which cases are verbs not
/// states. The process layer is thin — every decision lives here.
@Suite struct SystemTogglesTests {

    // MARK: - Shape

    @Test func theSetGrowsAtTheEndAndStaysStable() {
        // The original eight keep their order at the front — the strip
        // and a stored choice read them by position and name — and the
        // Mic, Eject and Sleep chips join after them.
        #expect(SystemToggle.allCases == [.keepAwake, .darkMode, .desktopIcons, .hiddenFiles,
                                          .mute, .screenSaver, .lock, .dockAutoHide,
                                          .micMute, .eject, .sleep])
        // Raw values persist in defaults — they must never drift.
        #expect(SystemToggle.keepAwake.rawValue == "keepAwake")
        #expect(SystemToggle.dockAutoHide.rawValue == "dockAutoHide")
        #expect(SystemToggle.micMute.rawValue == "micMute")
        #expect(SystemToggle.eject.rawValue == "eject")
        #expect(SystemToggle.sleep.rawValue == "sleep")
    }

    @Test func verbsAreMomentaryStatesAreToggles() {
        for verb in [SystemToggle.lock, .screenSaver, .eject, .sleep] {
            #expect(verb.isMomentary)
        }
        for toggle in [SystemToggle.keepAwake, .darkMode, .desktopIcons,
                       .hiddenFiles, .mute, .dockAutoHide, .micMute] {
            #expect(!toggle.isMomentary)
        }
    }

    @Test func sleepIsThePublicVerbAndTheRestStayInProcess() {
        #expect(SystemToggle.sleep.applyCommand(on: true) == "pmset sleepnow")
        // CoreAudio and NSWorkspace apply in-process.
        #expect(SystemToggle.micMute.applyCommand(on: true) == nil)
        #expect(SystemToggle.eject.applyCommand(on: true) == nil)
    }

    // MARK: - Lock honesty

    @Test func theLockDelayReadsSysadminctlsThreeAnswers() {
        #expect(SystemToggle.screenLockDelay(
            fromSysadminctl: "2026-09-22 18:03:28.535 sysadminctl[50830:8563188] screenLock delay is immediate")
                == .immediate)
        #expect(SystemToggle.screenLockDelay(fromSysadminctl: "screenLock delay is 300 seconds")
                == .after(seconds: 300))
        #expect(SystemToggle.screenLockDelay(fromSysadminctl: "screenLock delay is 0 seconds") == .immediate)
        #expect(SystemToggle.screenLockDelay(fromSysadminctl: "screenLock is off") == .off)
        #expect(SystemToggle.screenLockDelay(fromSysadminctl: "Error: not permitted") == nil)
    }

    @Test func theLockChipOnlySaysLockWhenItLocks() {
        #expect(SystemToggle.lockTitle(delay: .immediate) == "Lock")
        #expect(SystemToggle.lockTitle(delay: nil) == "Lock")
        #expect(SystemToggle.lockTitle(delay: .after(seconds: 300)) == "Display")
        #expect(SystemToggle.lockTitle(delay: .off) == "Display")
        #expect(SystemToggle.lock.help(on: false, lockDelay: .after(seconds: 300)).contains("5 min later"))
        #expect(SystemToggle.lock.help(on: false, lockDelay: .off).contains("does not lock"))
    }

    @Test func aTimedKeepAwakeSaysHowLongIsLeft() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let help = SystemToggle.keepAwake.help(on: true, awakeUntil: now.addingTimeInterval(90 * 60), now: now)
        #expect(help.contains("1 h 30 min"))
        #expect(SystemToggle.keepAwake.help(on: false, awakeKeepsDisplay: true).contains("will not lock"))
    }

    // MARK: - Eject

    @Test func sidePulseVolumesAreKnownByTheDaemonsOwnRule() {
        for name in ["SidePulse", "SIDEPULSE PRO", "Side Pulse", "sidepulse-dot", "PulseDot"] {
            #expect(SystemToggle.isLEDVolume(name: name), "\(name)")
        }
        for name in ["Pulse", "Backup", "Untitled", "My SidePulse"] {
            #expect(!SystemToggle.isLEDVolume(name: name), "\(name)")
        }
    }

    private func volume(_ name: String, path: String? = nil, ejectable: Bool = true, removable: Bool = true,
                        isInternal: Bool = false, local: Bool = true, root: Bool = false) -> SystemToggle.VolumeFacts {
        SystemToggle.VolumeFacts(name: name, path: path ?? "/Volumes/\(name)", ejectable: ejectable,
                                 removable: removable, isInternal: isInternal, local: local, root: root)
    }

    @Test func ejectTakesRemovableDisksAndLeavesTheStrip() {
        #expect(SystemToggle.shouldEject(volume("USB"), protectedPaths: []))
        // A disk image is ejectable without being removable.
        #expect(SystemToggle.shouldEject(volume("Installer", removable: false), protectedPaths: []))
        #expect(!SystemToggle.shouldEject(volume("SidePulse"), protectedPaths: []))
        // The daemon's mount list protects a strip whatever it is named.
        #expect(!SystemToggle.shouldEject(volume("NO NAME", path: "/Volumes/NO NAME"),
                                          protectedPaths: ["/Volumes/NO NAME/"]))
        #expect(!SystemToggle.shouldEject(volume("Macintosh HD", ejectable: false, removable: false,
                                                 isInternal: true, root: true), protectedPaths: []))
        #expect(!SystemToggle.shouldEject(volume("Data", ejectable: false, removable: false, isInternal: true),
                                          protectedPaths: []))
        #expect(!SystemToggle.shouldEject(volume("share", local: false), protectedPaths: []))
    }

    @Test func theEjectCaptionSaysWhatWentAndWhatStayed() {
        #expect(SystemToggle.ejectSummary(ejected: ["USB", "Backup"], refused: [], keptLED: ["SidePulse"])
                == "Ejected “USB” and “Backup”. “SidePulse” stays mounted.")
        #expect(SystemToggle.ejectSummary(ejected: [], refused: [("Backup", "it is in use")], keptLED: [])
                == "“Backup” stayed: it is in use.")
        #expect(SystemToggle.ejectSummary(ejected: [], refused: [], keptLED: []) == "Nothing to eject.")
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
