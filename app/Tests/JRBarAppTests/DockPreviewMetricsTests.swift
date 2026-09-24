import CoreGraphics
import Testing
@testable import JRBarApp

/// `DockPreviewMetrics` is the preview's one source of air: every inset
/// the panel, its cards and its ask rows draw comes from the card's
/// Spacing scale. Standard must be the look people had before the knob,
/// the tightest scale must keep the floors the ring and the verbs need,
/// and the corners must stay concentric at every step.
@Suite struct DockPreviewMetricsTests {
    /// The scale's range, in the fine slider's steps.
    private static let steps: [Double] = (10...32).map { Double($0) / 20 }

    private static func tokens(_ m: DockPreviewMetrics) -> [CGFloat] {
        [m.panelInset, m.sectionSpacing, m.cardPad, m.cardSpacing, m.captionGap,
         m.rowPadH, m.rowPadV, m.listPadH, m.headerIcon, m.verbDisc, m.plateRadius, m.panelRadius]
    }

    @Test func standardIsTheLookBeforeTheKnob() {
        let m = DockPreviewMetrics.scaled(1)
        #expect(m.panelInset == 10)
        #expect(m.sectionSpacing == 10)
        #expect(m.cardPad == 6)
        #expect(m.cardSpacing == 4)
        #expect(m.captionGap == 6)
        #expect(m.rowPadH == 10 && m.rowPadV == 8)
        #expect(m.listPadH == 8)
        #expect(m.headerIcon == 30)
        #expect(m.verbDisc == 22)
        #expect(m.showsRule)
        #expect(m.plateRadius == 14)
        #expect(m.panelRadius == 24, "the glass corner is concentric now: 8 + 6 + 10, not 20")
        #expect(DockPreviewMetrics.standard == m)
    }

    @Test func tightIsTheDefaultsNumbers() {
        let m = DockPreviewMetrics.scaled(0.6)
        #expect(m.panelInset == 6 && m.sectionSpacing == 6)
        #expect(m.cardPad == 4 && m.cardSpacing == 2 && m.captionGap == 4)
        #expect(m.rowPadH == 8 && m.rowPadV == 6 && m.listPadH == 6)
        #expect(m.headerIcon == 24 && m.verbDisc == 20)
        #expect(!m.showsRule, "below 0.8 the air alone separates the sections")
        #expect(m.plateRadius == 12 && m.panelRadius == 18)
    }

    @Test func everyTokenGrowsWithTheScale() {
        var previous = Self.tokens(DockPreviewMetrics.scaled(Self.steps[0]))
        for scale in Self.steps.dropFirst() {
            let current = Self.tokens(DockPreviewMetrics.scaled(scale))
            for (index, pair) in zip(previous, current).enumerated() {
                #expect(pair.1 >= pair.0, "token \(index) shrank at \(scale)")
            }
            previous = current
        }
    }

    @Test func roomyAddsAirNotBiggerControls() {
        for scale in Self.steps where scale >= 1 {
            let m = DockPreviewMetrics.scaled(scale)
            #expect(m.headerIcon == 30, "header icon at \(scale)")
            #expect(m.verbDisc == 22, "verb disc at \(scale)")
        }
        let roomy = DockPreviewMetrics.scaled(1.4)
        #expect(roomy.panelInset == 14 && roomy.cardPad == 8, "the air still grows")
    }

    @Test func theRuleShowsFromPointEight() {
        for scale in Self.steps {
            #expect(DockPreviewMetrics.scaled(scale).showsRule == (scale >= 0.8), "rule at \(scale)")
        }
    }

    @Test func theFloorsHoldAtTheTightestScale() {
        let m = DockPreviewMetrics.scaled(0.5)
        #expect(m.panelInset == 6, "the still's shadow still clears the clipped glass")
        #expect(m.sectionSpacing == 6)
        #expect(m.cardPad == 4, "the waiting ring reaches 3 pt past the still and must stay on its plate")
        #expect(m.cardSpacing == 2)
        #expect(m.captionGap == 3)
        #expect(m.rowPadH == 8 && m.rowPadV == 6 && m.listPadH == 6)
        #expect(m.headerIcon == 24)
        #expect(m.verbDisc == 20, "a verb disc stays a fair target")
        for scale in Self.steps {
            let t = DockPreviewMetrics.scaled(scale)
            #expect(t.cardPad >= 4 && t.panelInset >= 6 && t.verbDisc >= 20)
        }
    }

    @Test func theCornersStayConcentric() {
        for scale in Self.steps {
            let m = DockPreviewMetrics.scaled(scale)
            #expect(m.plateRadius == DockChrome.stillRadius + m.cardPad, "plate at \(scale)")
            #expect(m.panelRadius == m.plateRadius + m.panelInset, "glass at \(scale)")
        }
    }

    @Test func aScaleThatIsNotANumberIsStandard() {
        #expect(DockPreviewMetrics.scaled(.nan) == DockPreviewMetrics.standard)
    }
}
