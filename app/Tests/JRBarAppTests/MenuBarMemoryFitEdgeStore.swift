import CoreGraphics
import Foundation
@testable import JRBarApp

/// The learned fit edge kept in memory, so a test never touches
/// `UserDefaults`. The hider's own store is `MenuBarDefaultsFitEdgeStore`.
@MainActor
final class MenuBarMemoryFitEdgeStore: MenuBarFitEdgeStore {
    private(set) var edges: [String: CGFloat] = [:]
    func load(key: String) -> CGFloat? { edges[key] }
    func save(_ edge: CGFloat?, key: String) { edges[key] = edge }
}
