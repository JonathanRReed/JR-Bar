import Foundation
import Testing
@testable import JRBarLEDS

struct ProgramFixture: Decodable {
    struct Sample: Decodable {
        let t_ms: Int
        let colors: [[Int]]
    }
    let name: String
    let led_count: Int
    let program: String
    let samples: [Sample]
}

struct ParseVerdict: Decodable {
    let program: String
    let led_count: Int
    let ok: Bool
    let error_name: String?
    let line: Int
    let column: Int
}

struct CompilerFixture: Decodable {
    let program: String
    let led_count: Int
    let accepted: Bool
    let transformed: Bool
    let reasons: [String]
    let output: String
}

enum Fixtures {
    static var root: URL {
        Bundle.module.resourceURL!.appending(path: "Fixtures")
    }

    static func programs() throws -> [ProgramFixture] {
        let directory = root.appending(path: "programs")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try JSONDecoder().decode(ProgramFixture.self, from: Data(contentsOf: $0)) }
    }

    static func parseVerdicts() throws -> [ParseVerdict] {
        try JSONDecoder().decode([ParseVerdict].self, from: Data(contentsOf: root.appending(path: "parse_verdicts.json")))
    }

    static func compiler() throws -> [CompilerFixture] {
        try JSONDecoder().decode([CompilerFixture].self, from: Data(contentsOf: root.appending(path: "compiler.json")))
    }
}
