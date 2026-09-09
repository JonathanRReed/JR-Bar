import Foundation

public enum CoreCodecError: Error, Equatable, CustomStringConvertible {
    case emptyFrame
    case frameTooLarge(Int)
    case notAnObject
    case missingType
    case malformed(String)

    public var description: String {
        switch self {
        case .emptyFrame: return "empty frame"
        case .frameTooLarge(let size): return "frame of \(size) bytes exceeds \(CoreCodec.maxFrameBytes)"
        case .notAnObject: return "frame is not a JSON object"
        case .missingType: return "frame has no \"t\""
        case .malformed(let why): return "malformed frame: \(why)"
        }
    }
}

/// NDJSON framing: one JSON object per line. Decoding is by the `t`
/// discriminator; a type the app does not know decodes to `.unknown` and a
/// known type with extra keys decodes normally.
public enum CoreCodec {
    public static let maxFrameBytes = 1 << 20

    private struct Envelope: Decodable {
        let t: String?
        let v: Int?
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static func decode(frame: Data) throws -> CoreMessage {
        guard !frame.isEmpty else { throw CoreCodecError.emptyFrame }
        guard frame.count <= maxFrameBytes else { throw CoreCodecError.frameTooLarge(frame.count) }
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: frame)
        } catch {
            if (try? decoder.decode(JSONValue.self, from: frame)) != nil { throw CoreCodecError.notAnObject }
            throw CoreCodecError.malformed(String(describing: error))
        }
        guard let type = envelope.t else { throw CoreCodecError.missingType }
        if let version = envelope.v, version != CoreProtocol.version {
            return .unknown(type: type, version: version)
        }
        do {
            switch type {
            case "hello": return .hello(try decoder.decode(CoreHello.self, from: frame))
            case "state": return .state(try decoder.decode(CoreState.self, from: frame))
            case "lights": return .lights(try decoder.decode(CoreLights.self, from: frame))
            case "event": return .event(try decoder.decode(CoreEvent.self, from: frame))
            case "settings": return .settings(try decoder.decode(CoreSettings.self, from: frame))
            case "reply": return .reply(try decoder.decode(CoreReply.self, from: frame))
            case "log": return .log(try decoder.decode(CoreLog.self, from: frame))
            default: return .unknown(type: type, version: envelope.v)
            }
        } catch {
            throw CoreCodecError.malformed("\(type): \(error)")
        }
    }

    public static func decode(line: String) throws -> CoreMessage {
        try decode(frame: Data(line.utf8))
    }

    /// The wire bytes for a command, newline included.
    public static func encode(command: CoreCommand) throws -> Data {
        var data = try encoder.encode(command)
        data.append(0x0A)
        return data
    }

    public static func encode(value: JSONValue) throws -> Data {
        try encoder.encode(value)
    }

    public static func decodeCommand(frame: Data) throws -> CoreCommand {
        try decoder.decode(CoreCommand.self, from: frame)
    }
}

/// Splits a byte stream into newline-terminated frames, keeping the tail.
public struct NDJSONSplitter: Sendable {
    private var buffer = Data()
    public private(set) var droppedOversizedFrames = 0

    public init() {}

    /// Feed bytes; returns every complete frame (without its newline). A
    /// frame past the 1 MiB limit is dropped rather than buffered forever.
    public mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let frame = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            let trimmed = frame.last == 0x0D ? frame.dropLast() : frame[...]
            if trimmed.isEmpty { continue }
            frames.append(Data(trimmed))
        }
        if buffer.count > CoreCodec.maxFrameBytes {
            buffer.removeAll(keepingCapacity: false)
            droppedOversizedFrames += 1
        }
        return frames
    }

    public mutating func reset() { buffer.removeAll() }
}
