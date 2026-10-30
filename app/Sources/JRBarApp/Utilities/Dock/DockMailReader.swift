import AppKit
import os

struct DockMailMessage: Equatable, Sendable, Identifiable {
    let id: String
    let sender: String
    let subject: String
    let received: Date
    let flagged: Bool

    var url: URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard !id.isEmpty, let escaped = "<\(id)>".addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "message://" + escaped)
    }
}

struct DockMailReading: Equatable, Sendable {
    let unread: Int
    let messages: [DockMailMessage]
    let date: Date
}

enum DockMailError: Error, Equatable { case unavailable, denied, timeout, failed, malformed }

/// Owns only this card's child. Closing the card kills it and prevents a queued read.
final class DockMailCancellation: @unchecked Sendable {
    private struct State { var cancelled = false; var process: Process? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var cancelled: Bool { state.withLock { $0.cancelled } }
    func start(_ process: Process) throws {
        try state.withLock {
            guard !$0.cancelled else { throw DockMailError.unavailable }
            try process.run()
            $0.process = process
        }
    }
    func cancel() {
        state.withLock {
            $0.cancelled = true
            if let process = $0.process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            $0.process = nil
        }
    }
    func finished() { state.withLock { $0.process = nil } }
}

struct DockMailReader: Sendable {
    typealias Runner = @Sendable (String, [String], DockMailCancellation) -> Result<String, DockMailError>
    var isRunning: @Sendable () -> Bool = {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
    }
    var permission: @Sendable (Bool) -> AutomationPermission = {
        AutomationPermission.target("com.apple.mail", ask: $0)
    }
    var runner: Runner = Self.run

    func read(now: Date, cancellation: DockMailCancellation) -> Result<DockMailReading, DockMailError> {
        guard !cancellation.cancelled, isRunning() else { return .failure(.unavailable) }
        switch permission(false) {
        case .granted: break
        case .denied, .needsConsent: return .failure(.denied)
        case .unavailable: return .failure(.unavailable)
        }
        guard !cancellation.cancelled, isRunning() else { return .failure(.unavailable) }
        return runner(Self.script, [], cancellation).flatMap { output in
            do { return .success(try Self.parse(output, now: now)) }
            catch { return .failure(.malformed) }
        }
    }

    /// ASCII 30 separates rows and ASCII 31 separates fields. The script removes
    /// both from fields before joining; unexpected extra fields fail closed.
    static func parse(_ output: String, now: Date) throws -> DockMailReading {
        guard output.utf8.count <= 65_536 else { throw DockMailError.malformed }
        let rows = output.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1e}")
        guard let first = rows.first, let unread = Int(first), unread >= 0, rows.count <= 6 else {
            throw DockMailError.malformed
        }
        var messages: [DockMailMessage] = []
        for row in rows.dropFirst() {
            let fields = row.components(separatedBy: "\u{1f}")
            guard fields.count == 5, let seconds = TimeInterval(fields[3]), seconds.isFinite,
                  abs(seconds) < 100_000_000_000, ["true", "false"].contains(fields[4]) else {
                throw DockMailError.malformed
            }
            let id = clean(fields[0], limit: 512)
            guard !id.isEmpty, id == fields[0], !id.contains(" ") else { throw DockMailError.malformed }
            // An address-only sender has no display name. Never retain the address.
            let name = clean(fields[1], limit: 60)
            let sender = name.isEmpty || name.contains("@") ? "Unknown sender" : name
            let subject = clean(fields[2], limit: 120)
            messages.append(DockMailMessage(id: id, sender: sender,
                subject: subject.isEmpty ? "No subject" : subject,
                received: now.addingTimeInterval(seconds), flagged: fields[4] == "true"))
        }
        var seen = Set<String>()
        let newest = messages.sorted { $0.received > $1.received }.filter { seen.insert($0.id).inserted }
        return DockMailReading(unread: unread, messages: Array(newest.prefix(5)), date: now)
    }

    static func clean(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) &&
                !CharacterSet.illegalCharacters.contains($0)
        }
        return String(String(String.UnicodeScalarView(scalars)).prefix(limit))
    }

    static func run(_ script: String, _ arguments: [String], _ cancellation: DockMailCancellation)
        -> Result<String, DockMailError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        defer {
            cancellation.finished()
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        do { try cancellation.start(process) } catch { return .failure(.failed) }
        let output = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { drained.signal() }
            while let data = try? pipe.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                let oversized = output.withLock { bytes in
                    bytes.append(data)
                    return bytes.count > 65_536
                }
                if oversized { cancellation.cancel(); break }
            }
        }
        if exited.wait(timeout: .now() + 3) == .timedOut {
            cancellation.cancel()
            return .failure(.timeout)
        }
        guard drained.wait(timeout: .now() + 0.2) == .success,
              !cancellation.cancelled, process.terminationStatus == 0 else { return .failure(.failed) }
        return output.withLock { bytes in
            guard bytes.count <= 65_536, let text = String(data: bytes, encoding: .utf8) else {
                return .failure(.malformed)
            }
            return .success(text)
        }
    }

    /// Bounded mailbox walk. No bodies, headers, recipients, attachments or source.
    /// Mail's ordering and large-inbox speed require an owner-run installed check.
    static let script = """
    on safeText(value, cap)
        set resultText to ""
        repeat with c in characters of (value as text)
            set n to id of (c as text)
            if n > 31 and n is not 127 then set resultText to resultText & c
            if (count characters of resultText) >= cap then exit repeat
        end repeat
        return resultText
    end safeText
    on safeID(value)
        set keyText to my safeText(value, 512)
        if (id of keyText) is not (id of (value as text)) then error number -1700
        return keyText
    end safeID
    if not application id "com.apple.mail" is running then error number -600
    set rowSeparator to ASCII character 30
    set fieldSeparator to ASCII character 31
    set sampledAt to current date
    tell application id "com.apple.mail"
        with timeout of 3 seconds
            set resultText to (unread count of inbox) as text
            set messageCount to count messages of inbox
            set scanCount to 40
            if messageCount < scanCount then set scanCount to messageCount
            set foundCount to 0
            repeat with i from 1 to scanCount
                set m to message i of inbox
                if read status of m is false then
                    set senderName to extract name from (sender of m)
                    if senderName contains "@" then set senderName to "Unknown sender"
                    set keyText to my safeID(message id of m)
                    set nameText to my safeText(senderName, 60)
                    set subjectText to my safeText(subject of m, 120)
                    set receivedSeconds to ((date received of m) - sampledAt) as integer
                    set flagText to (flagged status of m) as text
                    set resultText to resultText & rowSeparator & keyText & fieldSeparator & nameText & fieldSeparator & subjectText & fieldSeparator & receivedSeconds & fieldSeparator & flagText
                    set foundCount to foundCount + 1
                    if foundCount = 5 then exit repeat
                end if
            end repeat
            return resultText
        end timeout
    end tell
    """

    static let replyScript = """
    on sameID(leftValue, rightValue)
        return (id of leftValue) is (id of rightValue)
    end sameID
    on run argv
        if not application id "com.apple.mail" is running then error number -600
        set wantedID to item 1 of argv
        tell application id "com.apple.mail"
            with timeout of 3 seconds
                set scanCount to count messages of inbox
                if scanCount > 40 then set scanCount to 40
                repeat with i from 1 to scanCount
                    set m to message i of inbox
                    if my sameID(message id of m, wantedID) then
                        reply m with opening window
                        activate
                        return "opened"
                    end if
                end repeat
                error number -1728
            end timeout
        end tell
    end run
    """
}
