import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp

/// "In full screen": hidden, shown except over a video, or always — and
/// the guard's own test of whether the app in front fills the screen.
@Suite("Screen Bar in full screen")
@MainActor
struct ScreenBarFullScreenTests {
    @Test func theChoiceIsTheDaemonsSwitchPlusTheAppsGuard() {
        #expect(ScreenBarFullScreen(shows: false, hideOverVideo: true) == .hidden)
        #expect(ScreenBarFullScreen(shows: false, hideOverVideo: false) == .hidden)
        #expect(ScreenBarFullScreen(shows: true, hideOverVideo: true) == .notOverVideo)
        #expect(ScreenBarFullScreen(shows: true, hideOverVideo: false) == .always)
        #expect(Set(ScreenBarFullScreen.allCases.map(\.title)).count == 3)
    }

    /// A 1512 × 982 built-in as the primary display, AppKit coordinates.
    private static let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func aFullScreenWindowCoversTheWholeScreen() {
        // Quartz puts the origin top-left; a full-screen window starts at 0.
        let full = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(ScreenBarController.coversScreen(windowBounds: [full], screenFrame: Self.builtIn, primaryHeight: 982))
    }

    @Test func aZoomedWindowStopsUnderTheMenuBar() {
        let zoomed = CGRect(x: 0, y: 38, width: 1512, height: 944)
        #expect(!ScreenBarController.coversScreen(windowBounds: [zoomed], screenFrame: Self.builtIn, primaryHeight: 982))
        #expect(!ScreenBarController.coversScreen(windowBounds: [], screenFrame: Self.builtIn, primaryHeight: 982))
    }

    @Test func aNotchedScreenPutsFullScreenUnderTheHousing() {
        // Full-screen content starts under the 32 pt housing; a zoomed
        // window under the 33 pt menu bar (a 14-inch MacBook Pro, measured).
        let underHousing = CGRect(x: 0, y: 32, width: 1512, height: 950)
        let zoomed = CGRect(x: 0, y: 33, width: 1512, height: 949)
        #expect(ScreenBarController.coversScreen(windowBounds: [underHousing], screenFrame: Self.builtIn,
                                                 primaryHeight: 982, topInset: 32))
        #expect(!ScreenBarController.coversScreen(windowBounds: [zoomed], screenFrame: Self.builtIn,
                                                  primaryHeight: 982, topInset: 32))
        #expect(!ScreenBarController.coversScreen(windowBounds: [underHousing], screenFrame: Self.builtIn,
                                                  primaryHeight: 982, topInset: 0), "a screen without a housing needs the top too")
    }

    @Test func aHalfPointOfRoundingStillCounts() {
        let rounded = CGRect(x: 0.5, y: 0.25, width: 1511.5, height: 981.75)
        #expect(ScreenBarController.coversScreen(windowBounds: [rounded], screenFrame: Self.builtIn, primaryHeight: 982))
    }

    @Test func aSecondaryScreenIsMeasuredInItsOwnPlace() {
        // An external above the built-in: AppKit y 982…2422, Quartz y −1440…0.
        let external = CGRect(x: -400, y: 982, width: 2560, height: 1440)
        let fullOnExternal = CGRect(x: -400, y: -1440, width: 2560, height: 1440)
        #expect(ScreenBarController.coversScreen(windowBounds: [fullOnExternal], screenFrame: external, primaryHeight: 982))
        #expect(!ScreenBarController.coversScreen(windowBounds: [fullOnExternal], screenFrame: Self.builtIn, primaryHeight: 982))
    }

    @Test func theRightNowLineSaysWhenItSteppedAside() {
        let line = ScreenBarSourceLine.describe(live: true, mirrorSetting: false, stripPresent: false, phaseOffsetMs: nil,
                                                why: nil, rejection: nil, motionNote: nil, followingAlcove: false,
                                                steppedAsideForVideo: true)
        #expect(line == "Its own display · stepped aside for a full-screen video")
    }
}
