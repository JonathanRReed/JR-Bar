import Foundation
import JRBarCore

/// The Overview's named cuts (S7.1): each preset is a *definition* over
/// the roster's fields, never a saved list of session ids — a stored view
/// must describe what to select so it still means something next week.
public enum OverviewPreset: String, Codable, CaseIterable, Sendable {
    case needsMe
    case failed
    case working
    case unreviewed
    case thisProject
    case thisMac
    case all
    /// One repository branch (or linked worktree): several agents working
    /// in worktrees of one repo read by branch, the way AgentNotch
    /// groups them. Needs the filter's `branch`.
    case thisBranch

    public var label: String {
        switch self {
        case .needsMe: return "Needs me"
        case .failed: return "Failed"
        case .working: return "Working"
        case .unreviewed: return "Unreviewed"
        case .thisProject: return "This project"
        case .thisMac: return "This Mac"
        case .all: return "All connected"
        case .thisBranch: return "This branch"
        }
    }

    /// The cuts the sidebar's Views section offers — `thisProject` and
    /// `thisBranch` are excluded: without a project or branch they match
    /// nothing, and the real entry points are the per-project and
    /// per-branch rows in their own sidebar sections.
    public static var sidebarPresets: [OverviewPreset] {
        allCases.filter { $0 != .thisProject && $0 != .thisBranch }
    }

    /// Whether the preset alone decides the row — `thisProject` also
    /// needs the filter's `project` to mean anything.
    public var needsProject: Bool { self == .thisProject }

    public func matches(_ entry: CoreRosterEntry) -> Bool {
        let session = entry.session
        switch self {
        case .needsMe:
            // Pinned (a live ask) or any ask the projection still carries.
            return entry.pinned || session.ask != nil
        case .failed:
            // The daemon's outcome axis, not a guessed lifecycle word.
            return entry.axes?.outcome == "failed"
        case .working:
            return SessionActivity.reduce(session) == .working
        case .unreviewed:
            // Finished work nobody has acknowledged yet.
            return entry.axes?.review == "unreviewed"
        case .thisProject:
            return true // decided by the filter's project below
        case .thisBranch:
            return true // decided by the filter's branch and the git lookup
        case .thisMac:
            return !session.remote
        case .all:
            return true
        }
    }
}

/// A saved view: preset + the project it narrows to + free text. The
/// definition is what persists; applying it to a fresh roster is the
/// whole point.
public struct OverviewFilter: Codable, Equatable, Hashable, Sendable {
    public var preset: OverviewPreset
    /// The project label (cwd tail) `thisProject` matches; nil otherwise.
    public var project: String?
    /// The "repo · branch" key `thisBranch` matches (`GitWorkspace.branchKey`).
    public var branch: String?

    public init(preset: OverviewPreset, project: String? = nil, branch: String? = nil) {
        self.preset = preset
        self.project = project
        self.branch = branch
    }

    /// `branchKey` resolves a row's cwd to its "repo · branch" key; the
    /// store passes its cached git lookup, and a filter that is not about
    /// branches never calls it.
    public func matches(_ entry: CoreRosterEntry, branchKey: (String?) -> String? = { _ in nil }) -> Bool {
        guard preset.matches(entry) else { return false }
        if preset.needsProject {
            guard let project, !project.isEmpty else { return false }
            return OverviewFilter.projectName(of: entry.session.cwd) == project
        }
        if preset == .thisBranch {
            guard let branch, !branch.isEmpty, !entry.session.remote else { return false }
            return branchKey(entry.session.cwd) == branch
        }
        return true
    }

    /// The label a project column shows for a cwd: the last two path
    /// components ("JR-Bar", "work/app") so same-named roots still differ.
    public static func projectName(of cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let components = trimmed.split(separator: "/").map(String.init)
        guard let last = components.last, last != "/" else { return trimmed.isEmpty ? nil : trimmed }
        return components.suffix(2).joined(separator: "/")
    }
}

/// A user-named saved view — the filter definition plus its label.
public struct SavedOverviewFilter: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var filter: OverviewFilter

    public init(name: String, filter: OverviewFilter) {
        self.name = name
        self.filter = filter
    }
}

/// Saved views persist as definitions in UserDefaults — they are view
/// state, and a stale build or daemon must never invent rows for them.
public enum OverviewSavedFilters {
    private static let key = "overview.savedFilters"

    public static func load(defaults: UserDefaults = .standard) -> [SavedOverviewFilter] {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([SavedOverviewFilter].self, from: data)
        else { return [] }
        return saved
    }

    public static func save(_ filters: [SavedOverviewFilter], defaults: UserDefaults = .standard) {
        let data = try? JSONEncoder().encode(filters)
        defaults.set(data, forKey: key)
    }
}

extension CoreSession {
    /// The one-line "what is it doing" — the roster's Current activity
    /// column shows this. Kept here (not in a graph file) because the
    /// table is the only surface that reads it.
    var activityCaption: String {
        if let ask { return ask.summary ?? "Waiting on you" }
        if let message, !message.isEmpty { return message }
        if let event { return event }
        if let tool { return tool }
        return mode?.replacingOccurrences(of: "_", with: " ") ?? "—"
    }
}
