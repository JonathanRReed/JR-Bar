import Foundation

@MainActor
final class DockShortcutsPreview {
    enum State: Equatable {
        case loading, unavailable
        case shortcuts([String])
        case stale([String])
    }
    enum RunState: Equatable { case idle, running, done, failed, timedOut }

    let reader: any DockShortcutsReading
    var onChange: () -> Void = {}
    private(set) var state: State = .loading
    private(set) var runs: [String: RunState] = [:]
    private var listCancellation: (() -> Void)?
    private var runCancellations: [String: () -> Void] = [:]
    private(set) var running = false
    private var epoch = 0

    init(reader: any DockShortcutsReading = DockShortcutsReader()) { self.reader = reader }

    func start() {
        guard !running else { return }
        running = true
        refresh()
    }

    func refresh() {
        guard running, listCancellation == nil else { return }
        let epoch = self.epoch
        let previous: [String]
        switch state {
        case .shortcuts(let names), .stale(let names): previous = names
        default: previous = []
        }
        listCancellation = reader.execute(["list"]) { [weak self] result in
            guard let self, self.running, self.epoch == epoch else { return }
            self.listCancellation = nil
            switch result {
            case .success(let output): self.state = .shortcuts(Self.names(output))
            case .failed, .timedOut: self.state = previous.isEmpty ? .unavailable : .stale(previous)
            }
            self.onChange()
        }
    }

    nonisolated static func names(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(separator: "\n").map(String.init).filter {
            !$0.isEmpty && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && seen.insert($0).inserted
        }
    }

    nonisolated static func openURL(_ name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "open-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    func run(_ name: String) {
        guard running, runCancellations.isEmpty, case .shortcuts(let names) = state,
              names.contains(name) else { return }
        runs[name] = .running
        onChange()
        let epoch = self.epoch
        runCancellations[name] = reader.execute(["run", name]) { [weak self] result in
            guard let self, self.running, self.epoch == epoch else { return }
            self.runCancellations.removeValue(forKey: name)
            switch result {
            case .success: self.runs[name] = .done
            case .failed: self.runs[name] = .failed
            case .timedOut: self.runs[name] = .timedOut
            }
            self.onChange()
        }
    }

    func stop() {
        running = false
        epoch += 1
        listCancellation?()
        listCancellation = nil
        for cancel in runCancellations.values { cancel() }
        runCancellations.removeAll()
        runs.removeAll()
        state = .loading
    }
}
