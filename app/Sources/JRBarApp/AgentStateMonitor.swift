import AppKit
import Foundation
import JRBarCore

extension AgentAggregateState {
    /// The mode colours from `_led_status_legacy.py`; nil keeps the menu
    /// bar's own tint. `tintHex` is the value the tests pin.
    var tint: NSColor? { tintHex.flatMap { NSColor(hex: $0) } }
}

/// Reads `~/.local/state/sidepulse/agent-monitor/latest.json` and reduces it
/// to one `AgentAggregateState`, re-reading only when the directory changes.
/// The reduction itself is `AgentMonitorFeed.reduce` in JRBarCore, so the
/// words and the precedence are unit-testable without AppKit.
@MainActor
final class AgentStateMonitor {
    static let directory = NSString(string: "~/.local/state/sidepulse/agent-monitor").expandingTildeInPath
    static let path = directory + "/latest.json"
    nonisolated static let completedWindow: TimeInterval = AgentMonitorFeed.completedWindow

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
            let result = AgentMonitorFeed.reduce(data)
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

    /// The file-feed reduction; `now` is injectable for the tests, which
    /// exercise this through `AgentMonitorFeed.reduce` in JRBarCore.
    nonisolated static func reduce(_ data: Data?, now: Date = Date()) -> (state: AgentAggregateState, detail: String) {
        AgentMonitorFeed.reduce(data, now: now)
    }
}
