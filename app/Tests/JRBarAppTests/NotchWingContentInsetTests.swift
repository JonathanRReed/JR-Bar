import AppKit
import Testing
import JRBarCore
import JRBarUI
@testable import JRBarApp

@MainActor
@Suite("Notch content clears persistent status wings")
struct NotchWingContentInsetTests {
    @Test func expandedContentKeepsItsBodyHeightAndClearsTheWingStrip() {
        let depth: CGFloat = 32
        let bodyHeight: CGFloat = 260
        let original = NotchIslandLayout.expandedTopInset(notchDepth: depth)
        let reserved = NotchToy.cardContentTopPad(notchDepth: depth, earsDrawn: true)
        #expect(reserved == original + ScreenBarGeometry.wingEarDrop)
        #expect(reserved > depth + ScreenBarGeometry.wingEarDrop)
        #expect((reserved + bodyHeight) - reserved == bodyHeight)
        #expect(NotchToy.cardContentTopPad(notchDepth: depth, earsDrawn: false) == original)
        #expect(NotchToy.cardContentTopPad(notchDepth: 0, earsDrawn: true)
                == NotchIslandLayout.expandedTopInset(notchDepth: 0))
    }

    @Test func noticeLevelAndTimerKeepTheirCopyRoomBelowTheWings() {
        let depth: CGFloat = 32
        for radius: CGFloat? in [nil, 8, 16] {
            let original = NotchIslandLayout.noticeSize(slotWidth: 185, notchDepth: depth,
                                                        underHousing: radius)
            let reserved = NotchToy.reservingWingContent(original, notchDepth: depth,
                                                         earsDrawn: true, underHousing: radius)
            let originalClimb = radius.map {
                NotchIslandLayout.housingClimb(size: original, notchDepth: depth, restingRadius: $0)
            } ?? 0
            let reservedClimb = radius.map {
                NotchIslandLayout.housingClimb(size: reserved, notchDepth: depth, restingRadius: $0)
            } ?? 0
            #expect(reserved.width == original.width)
            #expect(reserved.height - reservedClimb - depth - ScreenBarGeometry.wingEarDrop
                    >= original.height - originalClimb - depth)
        }
    }

    @Test func askAndMeetingVerbsKeepTheirRoomAcrossSummarySizes() {
        let depth: CGFloat = 32
        for takeover in [false, true] {
            for lines in [1, 3, 5] {
                let original = NotchIslandLayout.askSize(slotWidth: 185, notchDepth: depth,
                    summaryLines: lines, takeover: takeover, underHousing: 8)
                let reserved = NotchToy.reservingWingContent(original, notchDepth: depth,
                    earsDrawn: true, underHousing: 8)
                let oldClimb = NotchIslandLayout.housingClimb(size: original, notchDepth: depth, restingRadius: 8)
                let newClimb = NotchIslandLayout.housingClimb(size: reserved, notchDepth: depth, restingRadius: 8)
                #expect(reserved.width == original.width)
                #expect(reserved.height - newClimb - depth - ScreenBarGeometry.wingEarDrop >= original.height - oldClimb - depth)
            }
        }
    }

    @Test func reservationDependsOnConfigurationAndPhysicalDepthOnly() {
        let original = CGSize(width: 250, height: 70)
        #expect(NotchToy.reservingWingContent(original, notchDepth: 32,
            earsDrawn: false, underHousing: 8) == original)
        #expect(NotchToy.reservingWingContent(original, notchDepth: 0,
            earsDrawn: true, underHousing: nil) == original)
        #expect(NotchToy.wingContentInset(notchDepth: 32, earsDrawn: true) == 2)
        #expect(NotchToy.wingContentInset(notchDepth: 32, earsDrawn: false) == 0)
    }
}
