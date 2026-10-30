import Foundation

/// Reads the value already supplied by AppleDockReader, never the Messages database.
@MainActor
final class DockMessagesPreview {
    enum State: Equatable {
        case notRunning, noBadge, unread(String), badgeOnly, stale(String?)
    }
    var readBadge: (String?) -> State

    init(readBadge: @escaping (String?) -> State = DockMessagesPreview.read) { self.readBadge = readBadge }

    func update(running: Bool, badge: String?) -> State {
        running ? readBadge(badge) : .notRunning
    }

    nonisolated static func read(_ badge: String?) -> State {
        guard let badge, !badge.isEmpty else { return .noBadge }
        guard badge.utf8.count <= 12, badge.allSatisfy({ $0.isASCII && $0.isNumber }),
              badge.contains(where: { $0 != "0" }) else { return .badgeOnly }
        return .unread(badge)
    }
}
