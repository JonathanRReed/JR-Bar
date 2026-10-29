import Foundation
import Testing
@testable import JRBarCore

@Suite("Aquarium label layout")
struct AquariumLabelLayoutTests {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 450)

    @Test("clustered, crossing and spread chips stay disjoint and clear of banners",
          arguments: [1, 23, 50], ["cluster", "crossing", "spread", "edge"])
    func layoutMatrix(count: Int, layout: String) {
        let banner = CGRect(x: 160, y: 20, width: 480, height: 45)
        let candidates = (0..<count).map { i in
            let x: Double
            let y: Double
            switch layout {
            case "cluster": x = 300 + Double(i % 5) * 3; y = 170 + Double(i % 7) * 3
            case "crossing": x = Double(i % 10) * 60; y = 30 + Double(i % 6) * 14
            case "edge": x = Double(i % 10) * 80; y = i % 2 == 0 ? 0 : 435
            default: x = Double(i % 8) * 100; y = Double(i / 8) * 45
            }
            return AquariumLabelLayout.Candidate(id: "fish-\(i)", frame: CGRect(x: x, y: y, width: 90, height: 18),
                state: FishState.allCases[i % FishState.allCases.count], updatedAt: Double(i))
        }
        let selected = AquariumLabelLayout.visible(candidates, in: bounds, avoiding: [banner])
        let frames = candidates.filter { selected.contains($0.id) }.map(\.frame)
        for (index, frame) in frames.enumerated() {
            #expect(bounds.contains(frame))
            #expect(!banner.insetBy(dx: -4, dy: -4).intersects(frame))
            for other in frames.dropFirst(index + 1) { #expect(!frame.intersects(other)) }
        }
        #expect(selected == AquariumLabelLayout.visible(Array(candidates.reversed()), in: bounds, avoiding: [banner]))
        if layout == "cluster" { #expect(selected.count == 1) }
        if layout == "spread", count > 1 { #expect(selected.count > 1) }
    }

    @Test("asking leads working, then pointer distance, recency and stable identity")
    func priorities() {
        let frame = CGRect(x: 200, y: 200, width: 100, height: 20)
        func candidate(_ id: String, _ state: FishState, _ distance: Double, _ date: Double) -> AquariumLabelLayout.Candidate {
            .init(id: id, frame: frame, state: state, pointerDistance: distance, updatedAt: date)
        }
        let idle = candidate("idle", .idling, 0, 500)
        let working = candidate("working", .swimming, 100, 10)
        let asking = candidate("asking", .surfacing, 200, 0)
        #expect(AquariumLabelLayout.visible([idle, working, asking], in: bounds) == ["asking"])
        #expect(AquariumLabelLayout.visible([idle, working], in: bounds) == ["working"])
        let nearby = candidate("near", .swimming, 10, 0)
        #expect(AquariumLabelLayout.visible([working, nearby], in: bounds) == ["near"])
        let recent = candidate("recent", .swimming, .infinity, 50)
        let older = candidate("older", .swimming, .infinity, 10)
        #expect(AquariumLabelLayout.visible([older, recent], in: bounds) == ["recent"])
        let tie = candidate("a", .swimming, .infinity, 50)
        #expect(AquariumLabelLayout.visible([recent, tie], in: bounds) == ["a"])
    }

    @Test("long, empty and offscreen chips cannot escape the tank")
    func invalidFrames() {
        let frames = [CGRect.zero, CGRect(x: -20, y: 30, width: 100, height: 20),
                      CGRect(x: 0, y: 0, width: 1000, height: 20)]
        let candidates = frames.enumerated().map {
            AquariumLabelLayout.Candidate(id: String($0.offset), frame: $0.element, state: .swimming)
        }
        #expect(AquariumLabelLayout.visible(candidates, in: bounds).isEmpty)
    }
}
