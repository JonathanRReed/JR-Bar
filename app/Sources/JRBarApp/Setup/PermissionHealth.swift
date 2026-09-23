import Foundation

/// Grants that went away since JR-Bar last looked. A major macOS update
/// (or a bundle signed differently) can reset privacy grants, and the
/// first sign was a feature quietly stopping — Fold that no longer
/// folds, asks that no longer answer in the terminal. A launch compares
/// the rows against what was granted last time and says once which were
/// lost. Only rows the person granted count, so nothing is ever said
/// about a feature they never set up.
enum PermissionHealth {
    /// The rows a reset can take. The closed-lid helper is a sudoers rule
    /// JR-Bar's own Remove takes away, and system audio has no status
    /// read at all.
    nonisolated static let watched: [SetupPermission] = SetupPermission.allCases.filter {
        $0 != .lidHelper && $0 != .audioCapture
    }

    /// `lost`: remembered rows that now read needed or denied, in Setup's
    /// order. `remember`: what to keep for next time — every row granted
    /// now, plus remembered rows the probe could not read this time (an
    /// Unknown forgets nothing). A first look (`remembered == nil`) only
    /// records.
    nonisolated static func review(remembered: [String]?,
                                   statuses: [SetupPermission: SetupPermissionStatus])
        -> (lost: [SetupPermission], remember: [String]) {
        let before = Set(remembered ?? [])
        var lost: [SetupPermission] = []
        var keep: [String] = []
        for permission in watched {
            let status = statuses[permission] ?? .unknown
            switch status {
            case .granted:
                keep.append(permission.rawValue)
            case .needed, .denied:
                if remembered != nil, before.contains(permission.rawValue) { lost.append(permission) }
            case .unknown, .unavailable:
                if before.contains(permission.rawValue) { keep.append(permission.rawValue) }
            }
        }
        return (lost, keep)
    }

    /// The one-line notice: a single row names what stopped; several are
    /// listed by name.
    nonisolated static func notice(for lost: [SetupPermission]) -> String? {
        guard let first = lost.first else { return nil }
        if lost.count == 1 {
            return "\(first.title) was turned off since JR-Bar last ran — \(first.lostEffect)."
        }
        let titles = lost.map(\.title)
        let listed = titles.dropLast().joined(separator: ", ") + " and " + titles.last!
        return "\(listed) were turned off since JR-Bar last ran."
    }
}

extension SetupPermission {
    /// What stops while this grant is gone, as the tail of a sentence.
    nonisolated var lostEffect: String {
        switch self {
        case .notifications: return "no banners until it is back"
        case .calendar: return "the notch card has no next meeting"
        case .reminders: return "the shelf's reminders are gone"
        case .camera: return "the Mirror row cannot see"
        case .screenRecording: return "Fold cannot see the desktop"
        case .audioCapture: return "the media visualizer is still"
        case .bluetooth: return "connect announcements stop"
        case .accessibility: return "asks no longer answer in the terminal"
        case .automation: return "the Dark chip cannot switch"
        case .location: return "Wi-Fi rules cannot see the network"
        case .fullDiskAccess: return "Focus sync cannot see the Focus"
        case .focusStatus: return "Focus rules stop"
        case .lidHelper: return "the lid-closed hold is gone"
        }
    }
}
