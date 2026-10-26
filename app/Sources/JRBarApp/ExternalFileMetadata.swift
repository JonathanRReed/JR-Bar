import AppKit
import Darwin
import Observation
import UniformTypeIdentifiers

/// Automatic probes stay on local paths outside protected folders. Shelf consent is for
/// the exact item, never its siblings or a directory's contents.
struct ExternalFilePolicy: Sendable {
    let home: String
    var shelfPaths: Set<String> = []

    func allows(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        if shelfPaths.contains(path) { return true }
        let protected = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage",
                         "Pictures", "Movies", "Music", ".Trash"]
        if (path == home + "/Library" || path.hasPrefix(home + "/Library/")),
           !(path == home + "/Library/Sounds" || path.hasPrefix(home + "/Library/Sounds/")) { return false }
        if protected.contains(where: { path == home + "/" + $0 || path.hasPrefix(home + "/" + $0 + "/") }) {
            return false
        }
        let roots = ["/Applications", "/System/Applications", "/System/Library", "/Library", "/usr", "/tmp", "/private/tmp", "/var/folders", "/private/var/folders", home]
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Check each component before following it. In particular, an app alias
    /// in /Applications must not turn a safe probe into a Downloads read.
    static func localURL(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private" + path)
        }
        return url.standardizedFileURL
    }

    struct Facts: Sendable {
        var symbolicLink = false
        var dataless = false
        var local = true
    }

    func available(_ url: URL, inspect: (String) -> Facts? = ExternalFilePolicy.inspectLocal) -> Bool {
        guard allows(url) else { return false }
        var path = ""
        for part in Self.localURL(url).pathComponents.dropFirst() {
            path += "/" + part
            guard let facts = inspect(path), !facts.symbolicLink, !facts.dataless, facts.local else { return false }
        }
        return true
    }

    private static func inspectLocal(_ path: String) -> Facts? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        // Never ask statfs to follow a symlink or materialize a cloud item.
        if info.st_mode & S_IFMT == S_IFLNK { return Facts(symbolicLink: true) }
        if info.st_flags & UInt32(SF_DATALESS) != 0 { return Facts(dataless: true) }
        var filesystem = statfs()
        guard statfs(path, &filesystem) == 0 else { return nil }
        return Facts(local: filesystem.f_flags & UInt32(MNT_LOCAL) != 0)
    }
}

/// Images are fully decoded by the worker, then treated as immutable.
struct ExternalFileSnapshot: @unchecked Sendable {
    var available = false
    var directory = false
    var size: Int64?
    var bundleID: String?
    var icon: NSImage?
    var image: NSImage?
}

@MainActor
@Observable
final class ExternalFileMetadata {
    static let shared = ExternalFileMetadata()
    private(set) var version = 0
    @ObservationIgnored private var shelfPaths: Set<String> = []
    @ObservationIgnored private var shelfGrants: [String: UUID] = [:]
    @ObservationIgnored private let home: String
    @ObservationIgnored private let reader: @Sendable (Request) -> ExternalFileSnapshot?

    init(home: String = NSHomeDirectory(), reader: @escaping @Sendable (Request) -> ExternalFileSnapshot? = ExternalFileMetadata.read) {
        self.home = home
        self.reader = reader
    }
    @ObservationIgnored private lazy var cache = BackgroundLookupCache<Request, ExternalFileSnapshot>(
        changed: { [weak self] in Task { @MainActor in self?.version &+= 1 } },
        load: reader)
    @ObservationIgnored private lazy var icons = BackgroundLookupCache<Request, ExternalFileSnapshot>(
        changed: { [weak self] in Task { @MainActor in self?.version &+= 1 } }, load: Self.readIcon)
    @ObservationIgnored private let attachments = BackgroundLookupCache<Request, ExternalFileSnapshot>(
        limit: 1, capacity: 2, load: ExternalFileMetadata.readAttachment)

    struct Request: Hashable, Sendable {
        let url: URL
        let shelf: Bool
        var grant: UUID? = nil
        var iconPID: pid_t? = nil
    }

    func setShelfPaths(_ paths: Set<String>) {
        let normalized = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        shelfGrants = shelfGrants.filter { normalized.contains($0.key) }
        for path in normalized where shelfGrants[path] == nil { shelfGrants[path] = UUID() }
        shelfPaths = normalized
    }

    private func request(_ url: URL) -> Request {
        Request(url: url, shelf: shelfPaths.contains(url.path), grant: shelfGrants[url.path])
    }
    func invalidateViews() { version &+= 1 }

    func refresh(_ url: URL) {
        let normalized = url.standardizedFileURL
        cache.invalidate(request(normalized))
    }

    func resolve(_ url: URL) async -> ExternalFileSnapshot? {
        let normalized = url.standardizedFileURL
        guard ExternalFilePolicy(home: home, shelfPaths: shelfPaths).allows(normalized) else { return ExternalFileSnapshot() }
        return await cache.resolve(request(normalized))
    }

    func snapshot(_ url: URL) -> ExternalFileSnapshot? {
        _ = version
        let normalized = url.standardizedFileURL
        let request = request(normalized)
        guard ExternalFilePolicy(home: home, shelfPaths: shelfPaths).allows(normalized) else {
            return ExternalFileSnapshot()
        }
        return cache.value(for: request)
    }

    func cachedIcon(_ url: URL) -> NSImage? {
        _ = version
        let normalized = url.standardizedFileURL
        guard ExternalFilePolicy(home: home, shelfPaths: shelfPaths).allows(normalized) else { return nil }
        return icons.value(for: iconRequest(normalized))?.icon
    }

    private func iconRequest(_ url: URL) -> Request {
        var lookup = request(url)
        lookup.iconPID = RunningApps.shared.apps.first {
            $0.bundleURL?.standardizedFileURL == url
        }?.pid
        return lookup
    }

    func resolveIcon(_ url: URL) async -> NSImage? {
        let normalized = url.standardizedFileURL
        guard ExternalFilePolicy(home: home, shelfPaths: shelfPaths).allows(normalized) else { return nil }
        return await icons.resolve(iconRequest(normalized))?.icon
    }

    func icon(_ url: URL) -> NSImage {
        cachedIcon(url) ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }

    func attachment(_ url: URL) async -> NSImage? {
        let normalized = url.standardizedFileURL
        guard ExternalFilePolicy(home: home, shelfPaths: shelfPaths).allows(normalized) else { return nil }
        return await attachments.resolve(request(normalized))?.image
    }

    func bundleID(_ url: URL) -> String? {
        if let app = RunningApps.shared.apps.first(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) {
            return app.bundleID
        }
        return snapshot(url)?.bundleID
    }

    nonisolated static func read(_ request: Request) -> ExternalFileSnapshot? {
        let original = request.url
        let url = ExternalFilePolicy.localURL(original)
        let policy = ExternalFilePolicy(home: NSHomeDirectory(), shelfPaths: request.shelf ? [original.path] : [])
        guard policy.available(original) else { return ExternalFileSnapshot() }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return ExternalFileSnapshot() }
        var result = ExternalFileSnapshot(available: true, directory: info.st_mode & S_IFMT == S_IFDIR,
                                          size: Int64(info.st_size))
        if url.pathExtension == "app" { result.bundleID = Bundle(url: url)?.bundleIdentifier }
        return result
    }

    nonisolated private static func readIcon(_ request: Request) -> ExternalFileSnapshot? {
        let policy = ExternalFilePolicy(home: NSHomeDirectory(), shelfPaths: request.shelf ? [request.url.path] : [])
        guard policy.available(request.url) else { return nil }
        let running = request.iconPID.flatMap { NSRunningApplication(processIdentifier: $0)?.icon }
        let source = running ?? declaredIcon(request.url) ?? NSWorkspace.shared.icon(forFile: request.url.path)
        return ExternalFileSnapshot(icon: decoded(source))
    }

    nonisolated private static func declaredIcon(_ url: URL) -> NSImage? {
        guard url.pathExtension == "app", let bundle = Bundle(url: url),
              let raw = (bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String),
              !raw.isEmpty else { return nil }
        let name = (raw as NSString).deletingPathExtension
        return bundle.image(forResource: raw) ?? bundle.image(forResource: name)
    }

    nonisolated private static func readAttachment(_ request: Request) -> ExternalFileSnapshot? {
        let policy = ExternalFilePolicy(home: NSHomeDirectory(), shelfPaths: request.shelf ? [request.url.path] : [])
        guard policy.available(request.url) else { return nil }
        var info = stat()
        let url = ExternalFilePolicy.localURL(request.url)
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= ShelfTrayModel.attachCopyBound,
              let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let image = NSImage(contentsOf: url) else { return nil }
        return ExternalFileSnapshot(image: decoded(image))
    }

    nonisolated static func decoded(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard cg.width <= 16_384, cg.height <= 16_384, cg.width * cg.height <= 16_777_216 else { return nil }
        guard let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let decoded = context.makeImage() else { return nil }
        return NSImage(cgImage: decoded, size: image.size)
    }
}
