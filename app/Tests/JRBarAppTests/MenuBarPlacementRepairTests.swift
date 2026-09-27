import Foundation
import Testing
@testable import JRBarApp

@Suite("Menu bar placement must yield rather than cover controls")
struct MenuBarPlacementRepairTests {
    private func item(_ x: CGFloat, _ width: CGFloat = 30) -> CGRect {
        CGRect(x: x, y: 0, width: width, height: 24)
    }

    @Test func noSpaceReturnsNoSeat() {
        let crowded = stride(from: CGFloat(987), to: 1500, by: 37).map { item($0) }
        #expect(MenuBarIconMirror.seat(drawn: crowded, clearOf: 980, width: 38, rowMaxX: 1512) == nil)
    }

    @Test func incompleteDiscoveryDoesNotMeanEmptyBar() {
        #expect(MenuBarIconMirror.seat(drawn: [], clearOf: 980, width: 38, rowMaxX: 1512) == nil)
    }

    @Test func anOffDisplayItemCannotInventASeat() {
        #expect(MenuBarIconMirror.seat(drawn: [item(1600)], clearOf: 980,
                                       width: 38, rowMaxX: 1512) == nil)
    }

    @Test func oversizeFaceCannotCrossTheLeadingBoundary() {
        #expect(MenuBarIconMirror.seat(drawn: [item(1490)], clearOf: 1480,
                                       width: 70, rowMaxX: 1512) == nil)
    }

    @Test func aNarrowNativeSlotIsNotPermissionToCoverItsNeighbour() {
        let row = CGRect(x: 0, y: 0, width: 1512, height: 24)
        #expect(MenuBarIconMirror.slotSeat(realItem: item(1000, 24), width: 70,
                                           row: row, clearOf: 980, overflow: nil) == nil)
    }

    @Test func clearGapFitsEntireMirrorOnNegativeOriginDisplay() throws {
        let occupied = [item(-250), item(-180), item(-50)]
        let seat = try #require(MenuBarIconMirror.seat(drawn: occupied, clearOf: -400,
                                                       width: 70, rowMaxX: 0))
        #expect(seat >= -400 && seat + 70 <= 0)
        #expect(occupied.allSatisfy { $0.maxX <= seat || $0.minX >= seat + 70 })
    }

    @Test func occupiedSystemControlsAreNeverCovered() throws {
        for width in [CGFloat(24), 38, 70, 180] {
            let occupied = [item(1040, 30), item(1150, 70), item(1360, 152)]
            let candidate: CGFloat? = MenuBarIconMirror.seat(drawn: occupied, clearOf: 980,
                                                             width: width, rowMaxX: 1512)
            if let seat = candidate {
                #expect(seat >= 980 && seat + width <= 1512)
                #expect(occupied.allSatisfy { $0.maxX <= seat || $0.minX >= seat + width })
            }
        }
        #expect(MenuBarIconMirror.seat(drawn: [item(1100)], clearOf: 980,
                                       width: 70, rowMaxX: 1512) == 1023)
    }
    @Test func frozenBoundaryYieldsToANewControlRatherThanMovingOrCoveringIt() {
        #expect(MenuBarIconMirror.validatedSeat(1000, drawn: [item(1020)], clearOf: 980,
                                                width: 70, rowMaxX: 1512) == nil)
        #expect(MenuBarIconMirror.validatedSeat(1000, drawn: [], clearOf: 980,
                                                width: 70, rowMaxX: 1512) == nil)
        #expect(MenuBarIconMirror.validatedSeat(970, drawn: [item(1100)], clearOf: 980,
                                                width: 70, rowMaxX: 1512) == nil)
        #expect(MenuBarIconMirror.validatedSeat(1000, drawn: [item(1100)], clearOf: 980,
                                                width: 70, rowMaxX: 1512) == 1000)
    }

}
