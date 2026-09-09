import AppKit
import Foundation

/// The one-word state of everything the agent monitor knows about.
enum AgentAggregateState: Equatable {
    case idle
    case working
    case needsInput
    case completed
    case failed

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsInput: return "Needs input"
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }

    /// The mode colours from `_led_status_legacy.py`; nil keeps the menu bar's own tint.
    var tint: NSColor? {
        switch self {
        case .idle: return nil
        case .working: return NSColor(srgbRed: 0x00 / 255.0, green: 0xE5 / 255.0, blue: 0xFF / 255.0, alpha: 1)
        case .needsInput: return NSColor(srgbRed: 0xFF / 255.0, green: 0x3A / 255.0, blue: 0x00 / 255.0, alpha: 1)
        case .completed: return NSColor(srgbRed: 0x00 / 255.0, green: 0xFF / 255.0, blue: 0x66 / 255.0, alpha: 1)
        case .failed: return NSColor(srgbRed: 0xFF / 255.0, green: 0x3A / 255.0, blue: 0x00 / 255.0, alpha: 1)
        }
    }
}

/// Reads `~/.local/state/sidepulse/agent-monitor/latest.json` and reduces it
/// to one `AgentAggregateState`, re-reading only when the directory changes.
///
/// The file may carry either the public `agents` summary
/// (`lifecycle_counts` / `next_actor_counts`, as `serve.py` publishes) or the
/// raw version-2 `works` list; both are handled. Completed work only counts
/// as "Done" for a short window, the way the Python attention model treats
/// `COMPLETED_RECENTLY`.
@MainActor
final class AgentStateMonitor {
    static let directory = NSString(string: "~/.local/state/sidepulse/agent-monitor").expandingTildeInPath
    static let path = directory + "/latest.json"
    nonisolated static let completedWindow: TimeInterval = 90

    var onChange: (@MainActor (AgentAggregateState, String) -> Void)?
    private(set) var state: AgentAggregateState = .idle
    private(set) var detail: String = "No agent monitor state"
    private var watcher: FileWatcher?
    private var pending: DispatchWorkItem?
    private var generation = 0

    func start() {
        watcher = FileWatcher(path: Self.directory, mask: [.write, .link, .attrib, .delete, .rename, .revoke]) { [weak self] _ in
            self?.scheduleRead()
        }
        watcher?.start()
        scheduleRead()
    }

    private func scheduleRead() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.read() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func read() {
        generation += 1
        let generation = generation
        let path = Self.path
        Task.detached(priority: .utility) {
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            let result = Self.reduce(data)
            await MainActor.run { [weak self] in
                guard let self, self.generation == generation else { return }
                if result.state != self.state || result.detail != self.detail {
                    self.state = result.state
                    self.detail = result.detail
                    self.onChange?(result.state, result.detail)
                }
            }
        }
    }

    nonisolated static func reduce(_ data: Data?, now: Date = Date()) -> (state: AgentAggregateState, detail: String) {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (.idle, "No agent monitor state")
        }
        var lifecycle: [String: Int] = [:]
        var nextActor: [String: Int] = [:]
        var recentlyCompleted = 0
        if let agents = json["agents"] as? [String: Any] {
            lifecycle = (agents["lifecycle_counts"] as? [String: Int]) ?? [:]
            nextActor = (agents["next_actor_counts"] as? [String: Int]) ?? [:]
            recentlyCompleted = lifecycle["completed"] ?? 0
        } else if let works = json["works"] as? [[String: Any]] {
            for work in works {
                guard let life = work["lifecycle"] as? String, let actor = work["next_actor"] as? String else { continue }
                lifecycle[life, default: 0] += 1
                nextActor[actor, default: 0] += 1
                if life == "completed",
                   let watermark = work["watermark"] as? [String: Any],
                   let occurred = watermark["occurred_at_epoch"] as? Double,
                   now.timeIntervalSince1970 - occurred <= completedWindow {
                    recentlyCompleted += 1
                }
            }
        } else {
            return (.idle, "Unrecognised latest.json")
        }
        let active = (lifecycle["active"] ?? 0)
        let waiting = (lifecycle["waiting"] ?? 0) + (nextActor["user"] ?? 0)
        let failed = lifecycle["failed"] ?? 0
        let state: AgentAggregateState
        if waiting > 0 { state = .needsInput }
        else if failed > 0 { state = .failed }
        else if active > 0 { state = .working }
        else if recentlyCompleted > 0 { state = .completed }
        else { state = .idle }
        var parts: [String] = []
        if active > 0 { parts.append("\(active) working") }
        if waiting > 0 { parts.append("\(waiting) waiting on you") }
        if failed > 0 { parts.append("\(failed) failed") }
        if recentlyCompleted > 0 { parts.append("\(recentlyCompleted) just finished") }
        let total = lifecycle.values.reduce(0, +)
        let detail = parts.isEmpty ? (total > 0 ? "\(total) sessions, nothing live" : "No sessions") : parts.joined(separator: " · ")
        return (state, detail)
    }
}
