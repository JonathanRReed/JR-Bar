import Foundation

/// Keeps the most useful name chips when fish crowd together.
public enum AquariumLabelLayout {
    public struct Candidate: Sendable {
        public var id: String
        public var frame: CGRect
        public var priority: Int
        public var pointerDistance: Double
        public var updatedAt: Double

        public init(id: String, frame: CGRect, state: FishState, pointerDistance: Double = .infinity,
                    updatedAt: Double = 0) {
            self.id = id
            self.frame = frame
            self.priority = state == .surfacing ? 0 : state == .swimming ? 1 : 2
            self.pointerDistance = pointerDistance.isFinite ? pointerDistance : .infinity
            self.updatedAt = updatedAt.isFinite ? updatedAt : 0
        }
    }

    private struct Cell: Hashable { var x: Int; var y: Int }

    /// A priority sort followed by a grid pass. Each 8-point cell admits one chip.
    /// Work is bounded by chip area, rather than the number of other fish.
    public static func visible(_ candidates: [Candidate], in bounds: CGRect, avoiding obstacles: [CGRect] = []) -> Set<String> {
        let ordered = candidates.sorted { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            if a.pointerDistance != b.pointerDistance { return a.pointerDistance < b.pointerDistance }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.id < b.id
        }
        var occupied: Set<Cell> = []
        var visible: Set<String> = []
        for candidate in ordered {
            let frame = candidate.frame
            guard !frame.isEmpty, !frame.isInfinite, !frame.isNull, bounds.contains(frame),
                  !obstacles.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(frame) }) else { continue }
            let columns = Int(floor(frame.minX / 8))...Int(floor(frame.maxX / 8))
            let rows = Int(floor(frame.minY / 8))...Int(floor(frame.maxY / 8))
            var cells: [Cell] = []
            var collides = false
            for y in rows {
                for x in columns {
                    let cell = Cell(x: x, y: y)
                    if occupied.contains(cell) { collides = true; break }
                    cells.append(cell)
                }
                if collides { break }
            }
            guard !collides else { continue }
            occupied.formUnion(cells)
            visible.insert(candidate.id)
        }
        return visible
    }
}
