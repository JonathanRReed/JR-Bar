import Foundation
import Testing
@testable import JRBarCore

/// Capsule selection from window-list rows and the frame the band takes
/// while following it. Numbers are this MacBook Pro's: 1512×982 screen,
/// 32 pt notch, 185 pt slot, 14 pt wings.
@Suite struct AlcoveGeometryTests {
    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let primaryHeight: CGFloat = 982

    static func windowHeight(_ depth: CGFloat) -> CGFloat {
        max(max(0, depth) + 6, 6 + 14 + 2)
    }

    static func classicFrame(capsule: AlcoveCapsule?) -> CGRect {
        AlcoveGeometry.windowFrame(screenFrame: screen, notchWidth: 185, wing: 14, notchDepth: 32, capsule: capsule, windowHeight: windowHeight)
    }

    @Test func picksTheCapsuleHangingFromTheTop() {
        let rows = [
            // Alcove's onboarding window, a few hundred points down.
            AlcoveWindowRow(ownerName: "Alcove", number: 10695, layer: 0, bounds: CGRect(x: 524, y: 120, width: 464, height: 603)),
            // The capsule around the notch.
            AlcoveWindowRow(ownerName: "Alcove", number: 10700, layer: 2_147_483_629, bounds: CGRect(x: 650, y: 0, width: 212, height: 37)),
            // Ours, and someone else's.
            AlcoveWindowRow(ownerName: "JR-Bar", number: 10688, layer: 26, bounds: CGRect(x: 649, y: 0, width: 213, height: 38)),
        ]
        let capsule = AlcoveGeometry.select(rows: rows, screenFrame: Self.screen, primaryHeight: Self.primaryHeight)
        #expect(capsule == AlcoveCapsule(centerX: 756, width: 212, depth: 37))
    }

    @Test func nothingWithoutAlcoveWindowsAtTheTop() {
        let onboarding = [AlcoveWindowRow(ownerName: "Alcove", number: 1, layer: 0, bounds: CGRect(x: 524, y: 120, width: 464, height: 603))]
        #expect(AlcoveGeometry.select(rows: onboarding, screenFrame: Self.screen, primaryHeight: Self.primaryHeight) == nil)
        let tooWide = [AlcoveWindowRow(ownerName: "Alcove", number: 1, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1512, height: 30))]
        #expect(AlcoveGeometry.select(rows: tooWide, screenFrame: Self.screen, primaryHeight: Self.primaryHeight) == nil)
        let offScreen = [AlcoveWindowRow(ownerName: "Alcove", number: 1, layer: 0, bounds: CGRect(x: 1600, y: 0, width: 200, height: 30))]
        #expect(AlcoveGeometry.select(rows: offScreen, screenFrame: Self.screen, primaryHeight: Self.primaryHeight) == nil)
        let invisible = [AlcoveWindowRow(ownerName: "Alcove", number: 1, layer: 0, alpha: 0, bounds: CGRect(x: 650, y: 0, width: 212, height: 37))]
        #expect(AlcoveGeometry.select(rows: invisible, screenFrame: Self.screen, primaryHeight: Self.primaryHeight) == nil)
        #expect(AlcoveGeometry.select(rows: [], screenFrame: Self.screen, primaryHeight: Self.primaryHeight) == nil)
    }

    @Test func widestTopmostWindowWins() {
        let rows = [
            AlcoveWindowRow(ownerName: "Alcove", number: 5, layer: 100, bounds: CGRect(x: 700, y: 0, width: 112, height: 37)),
            AlcoveWindowRow(ownerName: "Alcove", number: 6, layer: 100, bounds: CGRect(x: 600, y: 0, width: 312, height: 90)),
        ]
        let capsule = AlcoveGeometry.select(rows: rows, screenFrame: Self.screen, primaryHeight: Self.primaryHeight)
        #expect(capsule?.width == 312)
        #expect(capsule?.depth == 90)
    }

    @Test func secondaryScreenUsesItsOwnTop() {
        // A display to the right whose top sits 200 pt above the primary's.
        let screen = CGRect(x: 1512, y: 200, width: 1920, height: 1080)
        let rows = [AlcoveWindowRow(ownerName: "Alcove", number: 9, layer: 0, bounds: CGRect(x: 2300, y: -298, width: 300, height: 40))]
        let capsule = AlcoveGeometry.select(rows: rows, screenFrame: screen, primaryHeight: Self.primaryHeight)
        #expect(capsule == AlcoveCapsule(centerX: 2450, width: 300, depth: 40))
    }

    /// Alcove 1.7.9 on this Mac: a 624×320 container hung from the top with
    /// two 35×32 controls laid out at the ends of the collapsed capsule.
    @Test func containerWindowIsRecognised() {
        let container = AlcoveWindowRow(ownerName: "Alcove", ownerPID: 51610, number: 10707, layer: 2_147_483_629, bounds: CGRect(x: 444, y: 0, width: 624, height: 320))
        let shadow = AlcoveWindowRow(ownerName: "Alcove", ownerPID: 51610, number: 10706, layer: 2_147_483_628, bounds: CGRect(x: 444, y: 0, width: 624, height: 320))
        let rows = [shadow, container, AlcoveWindowRow(ownerName: "JR-Bar", number: 1, layer: 26, bounds: CGRect(x: 649, y: 0, width: 213, height: 38))]
        #expect(AlcoveGeometry.select(rows: rows, screenFrame: Self.screen, primaryHeight: Self.primaryHeight) == nil)
        #expect(AlcoveGeometry.containerWindow(rows: rows, screenFrame: Self.screen, primaryHeight: Self.primaryHeight) == container)
        let onboardingOnly = [AlcoveWindowRow(ownerName: "Alcove", number: 1, layer: 0, bounds: CGRect(x: 524, y: 120, width: 464, height: 603))]
        #expect(AlcoveGeometry.containerWindow(rows: onboardingOnly, screenFrame: Self.screen, primaryHeight: Self.primaryHeight) == nil)
    }

    @Test func capsuleEstimatedFromContainerContent() {
        let container = CGRect(x: 444, y: 0, width: 624, height: 320)
        let frames = [CGRect(x: 663, y: 1, width: 35, height: 32), CGRect(x: 813, y: 1, width: 35, height: 32),
                      // The hosting view itself, and something laid out lower down: ignored.
                      container, CGRect(x: 600, y: 200, width: 100, height: 40)]
        let capsule = AlcoveGeometry.capsule(fromContentFrames: frames, container: container, screenFrame: Self.screen, primaryHeight: Self.primaryHeight)
        #expect(capsule == AlcoveCapsule(centerX: 755.5, width: 213, depth: 37))
        #expect(AlcoveGeometry.capsule(fromContentFrames: [container], container: container, screenFrame: Self.screen, primaryHeight: Self.primaryHeight) == nil)
        #expect(AlcoveGeometry.capsule(fromContentFrames: [], container: container, screenFrame: Self.screen, primaryHeight: Self.primaryHeight) == nil)
    }

    @Test func classicFrameWithoutACapsule() {
        let frame = Self.classicFrame(capsule: nil)
        #expect(frame == CGRect(x: 649.5, y: 944, width: 213, height: 38))
    }

    @Test func expandedCapsuleWidensAndDeepensTheBand() {
        let frame = Self.classicFrame(capsule: AlcoveCapsule(centerX: 756, width: 420, depth: 96))
        #expect(frame.width == 420)
        #expect(frame.height == 102)
        #expect(frame.midX == 756)
        #expect(frame.maxY == 982)
    }

    @Test func collapsedCapsuleNarrowsBelowTheNotch() {
        let frame = Self.classicFrame(capsule: AlcoveCapsule(centerX: 760, width: 160, depth: 30))
        #expect(frame.width == 160)
        #expect(frame.midX == 760)
        // The notch is deeper than the capsule: keep the notch's depth.
        #expect(frame.height == 38)
        // A capsule deeper than the notch hangs the band from its own bottom edge.
        #expect(Self.classicFrame(capsule: AlcoveCapsule(centerX: 760, width: 160, depth: 34)).height == 40)
        // Nothing narrower than 140 pt, whatever the window list says.
        let tiny = Self.classicFrame(capsule: AlcoveCapsule(centerX: 756, width: 60, depth: 34))
        #expect(tiny.width == 140)
    }

    @Test func capsuleCentreIsClampedToTheScreen() {
        let frame = Self.classicFrame(capsule: AlcoveCapsule(centerX: 10, width: 300, depth: 40))
        #expect(frame.minX == 0)
        #expect(frame.width == 300)
    }
}
