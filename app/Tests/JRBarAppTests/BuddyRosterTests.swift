import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// The Buddy card's roster: every tile stands still until one is hovered,
/// and one row or two is chosen from the width offered, as the
/// `ViewThatFits` it replaced chose — without building both every frame.
@Suite("Buddy roster")
@MainActor
struct BuddyRosterTests {
    // MARK: Buddy roster

    @Test("the roster stands still until a tile is hovered, and Reduce Motion stills that one too")
    func rosterStill() {
        for character in BuddyCharacter.allCases {
            #expect(!BuddyRosterPaces.paces(character, hovered: nil, reduceMotion: false))
        }
        #expect(BuddyRosterPaces.paces(.cat, hovered: .cat, reduceMotion: false))
        #expect(!BuddyRosterPaces.paces(.ghost, hovered: .cat, reduceMotion: false), "only the hovered tile")
        #expect(!BuddyRosterPaces.paces(.cat, hovered: .cat, reduceMotion: true))
    }

    @Test("the roster takes one row when the width holds it, else two even rows")
    func rosterRows() {
        let count = BuddyCharacter.allCases.count
        let cell: CGFloat = 48, inset: CGFloat = 4
        let oneRow = CGFloat(count) * cell - 2 * inset
        #expect(BuddyRosterLayout.perRow(count: count, cell: cell, inset: inset, width: nil) == count)
        #expect(BuddyRosterLayout.perRow(count: count, cell: cell, inset: inset, width: oneRow) == count)
        #expect(BuddyRosterLayout.perRow(count: count, cell: cell, inset: inset, width: oneRow - 1) == (count + 1) / 2)
        #expect(BuddyRosterLayout.perRow(count: 0, cell: cell, inset: inset, width: 100) == 0)
    }

    @Test("the roster lays out as the two stacked rows did")
    func rosterGeometry() {
        let tiles = ForEach(0..<10, id: \.self) { _ in Color.clear.frame(width: 48, height: 60) }
        let wide = NSHostingView(rootView: BuddyRosterLayout(cell: 48, inset: 4, rowSpacing: 8) { tiles }
            .fixedSize())
        #expect(abs(wide.fittingSize.width - (10 * 48 - 8)) < 0.5)
        #expect(abs(wide.fittingSize.height - 60) < 0.5)
        let narrow = NSHostingView(rootView: BuddyRosterLayout(cell: 48, inset: 4, rowSpacing: 8) { tiles }
            .frame(width: 300))
        #expect(abs(narrow.fittingSize.height - (60 * 2 + 8)) < 0.5, "\(narrow.fittingSize)")
    }
}
