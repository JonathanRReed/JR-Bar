import Foundation
import JRBarCore

/// `jrbar` in any terminal after a packaged install: a symlink at
/// ~/.local/bin/jrbar to the bundle's own `jrbar-core`, the one binary
/// that serves every CLI command (docs: README › Install). The packaged
/// app puts nothing on PATH by itself, so `jrbar doctor` or `jrbar quiet
/// 1h` meant an alias first.
///
/// Careful by design: it only ever creates the link where nothing is,
/// or replaces a link that points into some JR-Bar.app (an older
/// install); any other file at that path is someone else's and is left
/// alone.
enum CommandLineTool {
    enum State: Equatable, Sendable {
        /// Not a packaged bundle (a `swift run`): no binary to link.
        case unavailable
        case notInstalled
        case installed
        /// A link into another (or a moved) JR-Bar.app — safe to replace.
        case stale(String)
        /// Something that is not ours.
        case occupied
    }

    nonisolated static func linkURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".local/bin/jrbar")
    }

    nonisolated static func state(link: URL, bundled: String?, fileManager: FileManager = .default) -> State {
        guard let bundled else { return .unavailable }
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
            // Not a symlink: absent is free, anything else is not ours.
            return fileManager.fileExists(atPath: link.path) ? .occupied : .notInstalled
        }
        if (destination as NSString).standardizingPath == (bundled as NSString).standardizingPath {
            return .installed
        }
        return destination.contains("JR-Bar.app/Contents/Helpers/") || destination.contains("JR-Bar-dev.app/Contents/Helpers/")
            ? .stale(destination) : .occupied
    }

    /// Link `link` to `bundled`, replacing only a stale JR-Bar link.
    nonisolated static func install(link: URL, bundled: String, fileManager: FileManager = .default) throws {
        switch state(link: link, bundled: bundled, fileManager: fileManager) {
        case .installed:
            return
        case .occupied:
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: link.path])
        case .stale:
            try fileManager.removeItem(at: link)
        case .notInstalled, .unavailable:
            break
        }
        try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: bundled)
    }

    /// Remove the link — only when it is ours.
    nonisolated static func uninstall(link: URL, bundled: String?, fileManager: FileManager = .default) throws {
        switch state(link: link, bundled: bundled, fileManager: fileManager) {
        case .installed, .stale:
            try fileManager.removeItem(at: link)
        default:
            return
        }
    }
}
