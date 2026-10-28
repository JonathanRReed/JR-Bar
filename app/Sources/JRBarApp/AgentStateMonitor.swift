import AppKit
import Foundation
import JRBarCore

extension AgentAggregateState {
    /// The mode colours from `led_status.py`; nil keeps the menu
    /// bar's own tint. `tintHex` is the value the tests pin.
    var tint: NSColor? { tintHex.flatMap { NSColor(hex: $0) } }
}

/// Reads `~/.local/state/jrbar/latest.json` — the flat state dir
/// `CoreSocketPath.stateDirectory` resolves, the same place the daemon's
/// `default_latest_state_path()` writes — and reduces it to one
/// `AgentAggregateState`, re-reading only when the directory changes.
/// The reduction itself is `AgentMonitorFeed.reduce` in JRBarCore, so the
/// words and the precedence are unit-testable without AppKit.
///
/// It runs only while the daemon is not live: the result is the panel's
/// fallback, and a live daemon rewrites that directory dozens of times a
/// minute. The delegate stops it on connect and starts it again — with a
/// read at once, so the fallback is fresh — when the daemon goes away.
@MainActor
final class AgentStateMonitor {
    static let directory = CoreSocketPath.stateDirectory()

    var onChange: (@MainActor (AgentAggregateState, String) -> Void)?
    private(set) var state: AgentAggregateState = .idle
    private(set) var detail: String = AgentMonitorFeed.noStateDetail
    /// The watched directory and the document in it; tests point these
    /// at a scratch folder.
    let directory: String
    var path: String { directory + "/latest.json" }
    typealias Watch = (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    private let watch: Watch
    private let schedule: (DispatchWorkItem) -> Void
    private var cancelWatch: (@MainActor () -> Void)?
    private var watchGeneration = 0
    private var pending: DispatchWorkItem?
    private var generation = 0
    private(set) var readTask: Task<Void, Never>?

    init(directory: String = AgentStateMonitor.directory,
         watch: Watch? = nil,
         schedule: @escaping (DispatchWorkItem) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: $0)
         }) {
        self.directory = directory
        self.schedule = schedule
        self.watch = watch ?? { changed in
            let watcher = FileWatcher(path: directory, mask: [.write, .link, .attrib, .delete, .rename, .revoke]) { _ in
                changed()
            }
            watcher.start()
            return { watcher.stop() }
        }
    }

    /// Whether the directory is being watched.
    var isWatching: Bool { cancelWatch != nil }

    /// Watch the directory and read now. A second start while watching
    /// changes nothing.
    func start() {
        guard !isWatching else { return }
        watchGeneration += 1
        let watchGeneration = self.watchGeneration
        cancelWatch = watch { [weak self] in
            guard let self, self.isWatching, self.watchGeneration == watchGeneration else { return }
            self.scheduleRead()
        }
        pending?.cancel()
        pending = nil
        read()
    }

    /// Stop watching; a read already on its way is dropped.
    func stop() {
        cancelWatch?()
        cancelWatch = nil
        watchGeneration += 1
        pending?.cancel()
        pending = nil
        generation += 1
        readTask?.cancel()
    }

    private func scheduleRead() {
        pending?.cancel()
        let watchGeneration = self.watchGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isWatching, self.watchGeneration == watchGeneration else { return }
                self.read()
            }
        }
        pending = work
        schedule(work)
    }

    private func read() {
        generation += 1
        let generation = generation
        let path = self.path
        readTask = Task.detached(priority: .utility) {
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            // The doc's `last_clock` stamp is checked first; the mtime is
            // the fallback age for a document that carries no clock.
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            let result = AgentMonitorFeed.reduce(data, fileModifiedAt: modified)
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
}
