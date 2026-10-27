import Foundation

/// The interpreter tests run `scripts/mock-core.py` with. A bare `python3`
/// from PATH is the system 3.9 on a stock Mac, which the mock no longer
/// supports, so tests prefer, in order: `JRBAR_MOCK_PYTHON`, the repository's
/// own `.venv`, then `python3` from PATH.
public enum MockCorePython {
    /// The executable and any leading arguments to run a script with.
    public static func command(appDirectory: URL,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> (executable: URL, leading: [String]) {
        if let chosen = environment["JRBAR_MOCK_PYTHON"], !chosen.isEmpty, fileExists(chosen) {
            return (URL(fileURLWithPath: chosen), [])
        }
        let venv = appDirectory.deletingLastPathComponent().appending(path: ".venv/bin/python").path
        if fileExists(venv) { return (URL(fileURLWithPath: venv), []) }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["python3"])
    }
}
