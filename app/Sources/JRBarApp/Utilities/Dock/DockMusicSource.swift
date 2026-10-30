import AppKit
import Carbon
import JRBarCore

/// Music's scripting dictionary, addressed to a running PID. A closed target
/// cannot be launched by one of these events. No scripts or shell are run.
struct DockMusicSource {
    static let bundleID = "com.apple.Music"

    enum Repeat: String, CaseIterable, Sendable {
        case off, all, one
        var next: Self { self == .off ? .all : self == .all ? .one : .off }
    }
    struct Reading: Sendable {
        var media: AlcoveMedia?
        var shuffle = false
        var repeatMode: Repeat = .off
        var volume = 50.0
        var favorite: Bool?
    }
    enum Command: Equatable, Sendable {
        case transport(MediaRemoteBridge.Command)
        case seek(Double), volume(Double), shuffle(Bool), repeatMode(Repeat), favorite(Bool)
    }

    var isRunning: @MainActor () -> Bool
    var permission: @MainActor (Bool) async -> SetupPermissionStatus
    var read: @MainActor () async throws -> Reading
    var send: @MainActor (Command) async throws -> Void

    static func live() -> Self {
        Self(isRunning: { MusicEvents.runningPID() != nil }, permission: { ask in
            let work = Task.detached {
                guard !Task.isCancelled else { return SetupPermissionStatus.unavailable }
                return MusicEvents.permission(ask: ask)
            }
            return await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
        }, read: {
            let work = Task.detached {
                try Task.checkCancellation()
                return try MusicEvents().read()
            }
            return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        }, send: { command in
            let work = Task.detached {
                try Task.checkCancellation()
                try MusicEvents().send(command)
            }
            try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        })
    }
}

struct MusicEvents {
    enum Failure: Error { case unavailable, refused, malformed }
    let target: NSAppleEventDescriptor
    let deadline: TimeInterval
    let deliver: (NSAppleEventDescriptor, TimeInterval) throws -> NSAppleEventDescriptor

    init() throws {
        guard let pid = Self.runningPID() else { throw Failure.unavailable }
        self.init(pid: pid)
    }

    init(pid: pid_t, deliver: @escaping (NSAppleEventDescriptor, TimeInterval) throws -> NSAppleEventDescriptor = { event, timeout in
        try event.sendEvent(options: Self.sendOptions, timeout: timeout)
    }) {
        target = NSAppleEventDescriptor(processIdentifier: pid)
        deadline = ProcessInfo.processInfo.systemUptime + 3
        self.deliver = deliver
    }

    static func runningPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: DockMusicSource.bundleID)
            .first(where: { !$0.isTerminated })?.processIdentifier
    }

    static func permission(ask: Bool) -> SetupPermissionStatus {
        guard let pid = runningPID() else { return .unavailable }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let code = AEDeterminePermissionToAutomateTarget(target.aeDesc!, typeWildCard, typeWildCard, ask)
        switch AutomationPermission.classify(code) {
        case .granted: return .granted
        case .needsConsent: return .needed
        case .denied: return .denied
        case .unavailable: return .unavailable
        }
    }

    static let sendOptions = NSAppleEventDescriptor.SendOptions(rawValue:
        UInt(kAEWaitReply | kAENeverInteract | kAEDontReconnect | kAEDoNotPromptForUserConsent))

    static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    static func property(_ name: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: code("prop")), forKeyword: code("want"))
        record.setDescriptor(.init(enumCode: code("prop")), forKeyword: code("form"))
        record.setDescriptor(.init(typeCode: code(name)), forKeyword: code("seld"))
        record.setDescriptor(container, forKeyword: code("from"))
        return record.coerce(toDescriptorType: typeObjectSpecifier)!
    }

    func event(_ suite: String, _ verb: String, object: NSAppleEventDescriptor? = nil,
               value: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        try Task.checkCancellation()
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw Failure.unavailable }
        let event = NSAppleEventDescriptor(eventClass: Self.code(suite), eventID: Self.code(verb),
            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let object { event.setParam(object, forKeyword: keyDirectObject) }
        if let value { event.setParam(value, forKeyword: Self.code("data")) }
        let reply = try deliver(event, remaining)
        if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 {
            throw Failure.refused
        }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
    }

    func get(_ name: String, of container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        try event("core", "getd", object: Self.property(name, of: container))
    }

    func read() throws -> DockMusicSource.Reading {
        let state = try get("pPlS").enumCodeValue
        var reading = DockMusicSource.Reading()
        reading.volume = try get("pVol").doubleValue
        reading.shuffle = try get("pShE").booleanValue
        let repeatCode = try get("pRpt").enumCodeValue
        reading.repeatMode = repeatCode == Self.code("kAll") ? .all : repeatCode == Self.code("kRp1") ? .one : .off
        guard state != Self.code("kPSS") else { return reading }
        let track = try get("pTrk")
        let title = try get("pnam", of: track).stringValue ?? ""
        guard !title.isEmpty else { throw Failure.malformed }
        let artist = try get("pArt", of: track).stringValue
        let album = try get("pAlb", of: track).stringValue
        let duration = try get("pDur", of: track).doubleValue
        let position = try get("pPos").doubleValue
        let sampledAt = Date().timeIntervalSinceReferenceDate
        reading.favorite = try? get("pLov", of: track).booleanValue
        let artwork = NSAppleEventDescriptor.record()
        artwork.setDescriptor(.init(typeCode: Self.code("cArt")), forKeyword: Self.code("want"))
        artwork.setDescriptor(.init(enumCode: Self.code("indx")), forKeyword: Self.code("form"))
        artwork.setDescriptor(NSAppleEventDescriptor(int32: 1), forKeyword: Self.code("seld"))
        artwork.setDescriptor(track, forKeyword: Self.code("from"))
        let artObject = artwork.coerce(toDescriptorType: typeObjectSpecifier)!
        let art = try? get("pRaw", of: artObject).data
        let boundedArt = art.flatMap { $0.count <= 5 * 1024 * 1024 ? $0 : nil }
        reading.media = AlcoveMedia(title: String(title.prefix(300)), artist: artist.map { String($0.prefix(300)) },
            album: album.map { String($0.prefix(300)) }, playing: state == Self.code("kPSP"),
            artworkData: boundedArt, bundleIdentifier: DockMusicSource.bundleID,
            duration: duration.isFinite && duration > 0 ? duration : nil,
            elapsed: position.isFinite ? max(0, position) : nil, timestamp: sampledAt)
        return reading
    }

    func send(_ command: DockMusicSource.Command) throws {
        switch command {
        case .transport(let command):
            let verb = command == .togglePlayPause ? "PlPs" : command == .nextTrack ? "Next" : "Prev"
            _ = try event("hook", verb)
        case .seek(let seconds): try set("pPos", .init(double: seconds))
        case .volume(let volume): try set("pVol", .init(int32: Int32(DockMusicPreview.volume(volume))))
        case .shuffle(let enabled): try set("pShE", .init(boolean: enabled))
        case .repeatMode(let mode):
            let code = mode == .all ? "kAll" : mode == .one ? "kRp1" : "kRpO"
            try set("pRpt", .init(enumCode: Self.code(code)))
        case .favorite(let enabled): try set("pLov", .init(boolean: enabled), of: Self.property("pTrk"))
        }
    }

    func set(_ name: String, _ value: NSAppleEventDescriptor, of container: NSAppleEventDescriptor = .null()) throws {
        _ = try event("core", "setd", object: Self.property(name, of: container), value: value)
    }
}
