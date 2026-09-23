import Foundation
import JRBarCore

/// "Save as Effect…": tuned parameters kept as a named effect of your own
/// in one local pack, Yours — Chroma Studio's and Nanoleaf's "make it and
/// keep it", without the export-and-reimport round trip. The monitor stays
/// the only pack store: the app asks it to export the pack and the tuned
/// effect, adds one row, and hands the result back through
/// `import_effect_pack`. These are the pure halves of that.
enum EffectStudioYours {
    static let packID = "yours"
    static let packName = "Yours"

    enum Failure: Error, CustomStringConvertible {
        /// The monitor's export had no effect row where one was asked for.
        case malformedExport

        var description: String { "the monitor's export had no effect to copy" }
    }

    /// Whether a saved copy plays what the inspector plays. A provider
    /// animation carries its motion into the row and a pack effect is its
    /// own data, so both round-trip; any other built-in exports as
    /// metadata only and a copy would play its family's plain primitive —
    /// a different light under a name that promises this one.
    static func canSave(_ effect: EffectDefinition) -> Bool {
        effect.catalog == "provider_animation" || effect.isFromPack
    }

    static func isYours(_ effect: EffectDefinition) -> Bool { effect.pack == packID }

    /// The catalog id of a row in Yours.
    static func effectID(local: String) -> String { "pack:\(packID):\(local)" }

    /// The id an effect's row is exported under (`build_export_pack`): the
    /// last segment of a pack effect's id, a built-in's own id.
    static func localID(_ effectID: String) -> String {
        effectID.hasPrefix("pack:") ? String(effectID.split(separator: ":").last ?? Substring(effectID)) : effectID
    }

    /// A pack row id from a name: the monitor's data identifier
    /// (`[a-z0-9][a-z0-9._-]*`, at most 80), unique among `taken`.
    static func slug(_ name: String, taken: Set<String>) -> String {
        var slug = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "effect" }
        slug = String(slug.prefix(72))
        var candidate = slug
        var counter = 2
        while taken.contains(candidate) {
            candidate = "\(slug)-\(counter)"
            counter += 1
        }
        return candidate
    }

    /// The row ids of an exported pack, in order.
    static func rowIDs(_ pack: JSONValue?) -> [String] {
        (pack?["effects"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
    }

    /// Yours with a new row: the exported `source` row renamed to
    /// `newID`/`label` and holding `values`. A provider animation's
    /// "provider animation: …" meaning is replaced, or the library would
    /// file the copy back among the built-ins; any other meaning is kept,
    /// because a row without a motion is rendered from it. The row's
    /// reduced-motion fallback named a row of the other pack, so it goes.
    static func pack(yours: JSONValue?, source: JSONValue, sourceLabel: String,
                     newID: String, label: String, values: [String: JSONValue]) throws -> JSONValue {
        guard case .object(var row)? = source["effects"]?.arrayValue?.first else { throw Failure.malformedExport }
        row["id"] = .string(newID)
        row["label"] = .string(label)
        row.removeValue(forKey: "reduce_motion_fallback")
        if let meaning = row["meaning"]?.stringValue, meaning.lowercased().hasPrefix("provider animation") {
            row["meaning"] = .string("yours: \(sourceLabel), tuned")
        }
        for (name, value) in values { row[name] = value }
        var pack = yours?.objectValue ?? source.objectValue ?? [:]
        pack["id"] = .string(packID)
        pack["name"] = .string(packName)
        pack["effects"] = .array((yours?["effects"]?.arrayValue ?? []) + [.object(row)])
        return .object(pack)
    }

    /// Yours without the row `localID`, or nil when it was the last one —
    /// an empty pack is removed, not kept.
    static func pack(yours: JSONValue, removing localID: String) -> JSONValue? {
        guard case .object(var pack) = yours else { return nil }
        let rows = (pack["effects"]?.arrayValue ?? []).filter { $0["id"]?.stringValue != localID }
        guard !rows.isEmpty else { return nil }
        pack["effects"] = .array(rows)
        return .object(pack)
    }

    /// The pack as JSON text, numbers spelled the way the monitor will
    /// read them back. It types a pack parameter by its literal, so a
    /// tuned 2.0 written as `2` would come back an integer slider;
    /// `floatKeys(rowID)` names each row's real-number parameters, which
    /// keep a fraction. Keys are sorted, so the same pack is the same text.
    static func text(_ pack: JSONValue, floatKeys: (String) -> Set<String>) -> String {
        func quoted(_ string: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return (try? encoder.encode(string)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }
        func number(_ value: Double, float: Bool) -> String {
            guard value.isFinite else { return "null" }
            if value == value.rounded(), abs(value) < 1e15 {
                return float ? "\(Int64(value)).0" : "\(Int64(value))"
            }
            return "\(value)"
        }
        func write(_ value: JSONValue, float: Bool, keys: ((String) -> Bool)?) -> String {
            switch value {
            case .null: return "null"
            case .bool(let flag): return flag ? "true" : "false"
            case .number(let n): return number(n, float: float)
            case .string(let s): return quoted(s)
            case .array(let items):
                return "[" + items.map { write($0, float: float, keys: nil) }.joined(separator: ",") + "]"
            case .object(let members):
                let body = members.keys.sorted().map { key in
                    quoted(key) + ":" + write(members[key] ?? .null, float: keys?(key) ?? false, keys: nil)
                }
                return "{" + body.joined(separator: ",") + "}"
            }
        }
        guard case .object(let members) = pack else { return write(pack, float: false, keys: nil) }
        let body = members.keys.sorted().map { key -> String in
            let value = members[key] ?? .null
            guard key == "effects", case .array(let rows) = value else {
                return quoted(key) + ":" + write(value, float: false, keys: nil)
            }
            let written = rows.map { row -> String in
                let floats = floatKeys(row["id"]?.stringValue ?? "")
                return write(row, float: false, keys: { floats.contains($0) })
            }
            return quoted(key) + ":[" + written.joined(separator: ",") + "]"
        }
        return "{" + body.joined(separator: ",") + "}"
    }

    /// A row's real-number parameters, from the effect's typed parameters.
    static func floatKeys(of effect: EffectDefinition?) -> Set<String> {
        Set((effect?.parameters ?? []).filter { $0.type == .number }.map(\.name))
    }
}
