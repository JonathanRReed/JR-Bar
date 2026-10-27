import Foundation

/// Owns only its unique directory. Copies of a scratch document share this owner.
public final class ScratchDirectory: Sendable {
    public let url: URL

    public init(parent: URL = FileManager.default.temporaryDirectory) {
        url = parent.appendingPathComponent("jrbar-scratch-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
