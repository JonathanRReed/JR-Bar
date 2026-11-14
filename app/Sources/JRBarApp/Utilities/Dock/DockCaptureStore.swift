import AppKit

/// The window stills the Dock previews and the ⌥⇥ switcher keep
/// (docs/UTILITIES.md). Two jobs with two ages:
///
/// - A still younger than `DockThumbnailer.captureLifetime` stands in for
///   a new capture, so hovering a window twice in half a minute does not
///   blink the recording indicator twice.
/// - A still up to `keep` old is the window's last-known picture. A
///   repeat hover shows it on the first frame, before ScreenCaptureKit
///   has even listed the windows, and the fresh capture replaces it when
///   it lands.
///
/// The store is bounded by decoded bytes, not by count: a few large
/// windows cost what dozens of small ones do. Past the limit the least
/// recently shown stills go first. Nothing here reads a clock or the
/// screen; the caller passes the time.
struct DockCaptureStore {
    struct Entry {
        var image: NSImage
        var at: Date
        var tag: String?
        var cost: Int
        fileprivate var used: UInt64
    }

    /// The most decoded bytes the store holds.
    static let byteLimit = 32 << 20
    /// How long a still may stand in as a window's last-known picture.
    static let keep: TimeInterval = 10 * 60

    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var bytes = 0
    let limit: Int

    init(limit: Int = DockCaptureStore.byteLimit) {
        self.limit = max(0, limit)
    }

    var count: Int { entries.count }

    static func key(pid: pid_t, windowID: CGWindowID) -> String { "\(pid):\(windowID)" }

    /// The bytes an image costs once decoded: four a pixel of its largest
    /// bitmap, and a point-size guess for an image with no bitmap.
    static func cost(of image: NSImage) -> Int {
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        if pixels > 0 { return pixels * 4 }
        return max(1, Int(image.size.width * image.size.height)) * 4
    }

    /// Keep `image` for `key`, replacing what was there, then make room.
    /// An image bigger than the whole store is not kept at all.
    mutating func store(_ image: NSImage, key: String, tag: String?, at now: Date, cost: Int? = nil) {
        remove(key)
        let cost = max(1, cost ?? Self.cost(of: image))
        guard cost <= limit else { return }
        clock &+= 1
        entries[key] = Entry(image: image, at: now, tag: tag, cost: cost, used: clock)
        bytes += cost
        prune(now: now)
    }

    /// The still for `key`, marked as just shown. Nil once it is older
    /// than `keep`.
    mutating func entry(_ key: String, now: Date) -> Entry? {
        guard var found = entries[key] else { return nil }
        guard now.timeIntervalSince(found.at) < Self.keep else {
            remove(key)
            return nil
        }
        clock &+= 1
        found.used = clock
        entries[key] = found
        return found
    }

    /// The still's age and tag without marking it shown.
    func peek(_ key: String, now: Date) -> (age: TimeInterval, tag: String?)? {
        entries[key].map { (now.timeIntervalSince($0.at), $0.tag) }
    }

    mutating func remove(_ key: String) {
        guard let old = entries.removeValue(forKey: key) else { return }
        bytes -= old.cost
    }

    mutating func removeAll() {
        entries.removeAll()
        bytes = 0
    }

    /// Drop every still past `keep`, then the least recently shown ones
    /// until the store is inside its limit.
    mutating func prune(now: Date) {
        for (key, entry) in entries where now.timeIntervalSince(entry.at) >= Self.keep {
            remove(key)
        }
        guard bytes > limit else { return }
        for key in entries.keys.sorted(by: { entries[$0]!.used < entries[$1]!.used }) {
            guard bytes > limit else { break }
            remove(key)
        }
    }
}
