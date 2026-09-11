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

    /// `t`/`v` read out of the same keyed container the payload then
    /// decodes from, so a frame is parsed once.
    private struct FrameKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private enum CoreFrame: Decodable {
        case hello(CoreHello)
        case state(CoreState)
        case lights(CoreLights)
        case event(CoreEvent)
        case settings(CoreSettings)
        case reply(CoreReply)
        case log(CoreLog)
        case unknown(type: String, version: Int?)

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: FrameKey.self)
            guard let type = try container.decodeIfPresent(String.self, forKey: FrameKey(stringValue: "t")!) else {
                throw CoreCodecError.missingType
            }
            let version = try container.decodeIfPresent(Int.self, forKey: FrameKey(stringValue: "v")!)
            if let version, version != CoreProtocol.version {
                self = .unknown(type: type, version: version)
                return
            }
            do {
                switch type {
                case "hello": self = .hello(try CoreHello(from: decoder))
                case "state": self = .state(try CoreState(from: decoder))
                case "lights": self = .lights(try CoreLights(from: decoder))
                case "event": self = .event(try CoreEvent(from: decoder))
                case "settings": self = .settings(try CoreSettings(from: decoder))
                case "reply": self = .reply(try CoreReply(from: decoder))
                case "log": self = .log(try CoreLog(from: decoder))
                default: self = .unknown(type: type, version: version)
                }
            } catch {
                throw CoreCodecError.malformed("\(type): \(error)")
            }
        }

        var message: CoreMessage {
            switch self {
            case .hello(let payload): return .hello(payload)
            case .state(let payload): return .state(payload)
            case .lights(let payload): return .lights(payload)
            case .event(let payload): return .event(payload)
            case .settings(let payload): return .settings(payload)
            case .reply(let payload): return .reply(payload)
            case .log(let payload): return .log(payload)
            case .unknown(let type, let version): return .unknown(type: type, version: version)
            }
        }
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
        do {
            return try decoder.decode(CoreFrame.self, from: frame).message
        } catch let error as CoreCodecError {
            throw error
        } catch {
            // A structural failure (not a JSON object, or `t`/`v` of the
            // wrong kind): same ruling the envelope pass gave -- a frame
            // that is still valid JSON reads `.notAnObject`, one that is
            // not reads `.malformed`.
            if (try? decoder.decode(JSONValue.self, from: frame)) != nil { throw CoreCodecError.notAnObject }
            throw CoreCodecError.malformed(String(describing: error))
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
