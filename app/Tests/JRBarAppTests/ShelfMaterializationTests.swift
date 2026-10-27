import JRBarTestSupport
import Foundation
import Testing
@testable import JRBarApp

@Suite("Shelf materialization", .temporaryDirectory)
@MainActor
struct ShelfMaterializationTests {
    private func scratchDirectory() -> URL {
        TestTemporaryDirectory.currentURL
            .appendingPathComponent("jrbar-materialization-\(UUID().uuidString)")
    }

    @Test func collidingTextsKeepTheirContentsAndPaths() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = "Synthetic shelf collision example\n52c5b527892fbc0d"
        let second = "Synthetic shelf collision example\n21a9a64f78a59c1e"
        #expect(ShelfTrayDrop.stableHash(first) == "6f83b4cd")
        #expect(ShelfTrayDrop.stableHash(second) == "6f83b4cd")
        let firstURL = try #require(ShelfTrayDrop.textLoc(for: first, directory: directory))
        let secondURL = try #require(ShelfTrayDrop.textLoc(for: second, directory: directory))
        #expect(firstURL != secondURL)
        #expect(try String(contentsOf: firstURL, encoding: .utf8) == first)
        #expect(try String(contentsOf: secondURL, encoding: .utf8) == second)
        #expect(ShelfTrayDrop.textLoc(for: first, directory: directory) == firstURL)
        #expect(ShelfTrayDrop.textLoc(for: second, directory: directory) == secondURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test func editedTextSurvivesAndMatchingClipSurvivesANumberedGap() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "Synthetic editable clip"
        let original = try #require(ShelfTrayDrop.textLoc(for: text, directory: directory))
        try "First external edit".write(to: original, atomically: true, encoding: .utf8)
        let second = try #require(ShelfTrayDrop.textLoc(for: text, directory: directory))
        #expect(second != original)
        try "Second external edit".write(to: second, atomically: true, encoding: .utf8)
        let third = try #require(ShelfTrayDrop.textLoc(for: text, directory: directory))
        #expect(third != original)
        #expect(third != second)
        #expect(try String(contentsOf: original, encoding: .utf8) == "First external edit")
        #expect(try String(contentsOf: second, encoding: .utf8) == "Second external edit")
        try FileManager.default.removeItem(at: second)
        #expect(ShelfTrayDrop.textLoc(for: text, directory: directory) == third)
        #expect(try String(contentsOf: third, encoding: .utf8) == text)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test(arguments: [false, true])
    func editedOrMalformedWeblocSurvives(malformed: Bool) throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = try #require(URL(string: "https://example.com/synthetic-clip"))
        let original = try #require(ShelfTrayDrop.webLoc(for: link, directory: directory))
        let replacement: Data
        if malformed {
            replacement = Data("Externally edited, no longer a plist".utf8)
        } else {
            replacement = try PropertyListSerialization.data(
                fromPropertyList: ["URL": "https://example.com/external-edit"],
                format: .xml, options: 0)
        }
        try replacement.write(to: original)
        let fresh = try #require(ShelfTrayDrop.webLoc(for: link, directory: directory))
        #expect(fresh != original)
        #expect(try Data(contentsOf: original) == replacement)
        #expect(ShelfTrayDrop.webLoc(for: link, directory: directory) == fresh)
        let plist = try #require(NSDictionary(contentsOf: fresh))
        #expect(plist["URL"] as? String == link.absoluteString)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test func danglingSymlinkIsPreserved() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "Synthetic symlink clip"
        let original = try #require(ShelfTrayDrop.textLoc(for: text, directory: directory))
        try FileManager.default.removeItem(at: original)
        let missing = directory.appendingPathComponent("missing-target.txt")
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: missing)
        let fresh = try #require(ShelfTrayDrop.textLoc(for: text, directory: directory))
        #expect(fresh != original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: original.path) == missing.path)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(try String(contentsOf: fresh, encoding: .utf8) == text)
        #expect(ShelfTrayDrop.textLoc(for: text, directory: directory) == fresh)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test func unwritableDestinationReturnsNil() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("Synthetic occupied directory path".utf8).write(to: directory)
        let link = try #require(URL(string: "https://example.com/synthetic-failure"))
        #expect(ShelfTrayDrop.textLoc(for: "Synthetic clip", directory: directory) == nil)
        #expect(ShelfTrayDrop.webLoc(for: link, directory: directory) == nil)
        #expect(try String(contentsOf: directory, encoding: .utf8) == "Synthetic occupied directory path")
    }

    @Test(arguments: [false, true])
    func concurrentClipsReuseOnePathPerContent(colliding: Bool) async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = "Synthetic shelf collision example\n52c5b527892fbc0d"
        let second = colliding
            ? "Synthetic shelf collision example\n21a9a64f78a59c1e" : first
        let results = await Task.detached {
            await withTaskGroup(of: (String, URL?).self) { group in
                for index in 0..<24 {
                    let text = index.isMultiple(of: 2) ? first : second
                    group.addTask { (text, ShelfTrayDrop.textLoc(for: text, directory: directory)) }
                }
                var collected: [(String, URL?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
        }.value
        #expect(results.count == 24)
        var paths: [String: Set<URL>] = [:]
        for (text, result) in results {
            let url = try #require(result)
            paths[text, default: []].insert(url)
            #expect(try String(contentsOf: url, encoding: .utf8) == text)
        }
        #expect(paths.count == (colliding ? 2 : 1))
        for (text, urls) in paths {
            #expect(urls.count == 1)
            #expect(ShelfTrayDrop.textLoc(for: text, directory: directory) == urls.first)
        }
        let published = Set(results.compactMap { $0.1?.lastPathComponent })
        let contents = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(contents == published)
        #expect(contents.count == (colliding ? 2 : 1))
    }

    @Test func binaryWeblocAtLegacyNameIsReused() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = try #require(URL(string: "https://example.com/synthetic-binary"))
        let legacy = directory.appendingPathComponent(
            "example.com-\(ShelfTrayDrop.stableHash(link.absoluteString)).webloc")
        let binary = try PropertyListSerialization.data(
            fromPropertyList: ["URL": link.absoluteString], format: .binary, options: 0)
        try binary.write(to: legacy)
        #expect(ShelfTrayDrop.webLoc(for: link, directory: directory) == legacy)
        #expect(try Data(contentsOf: legacy) == binary)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [legacy.lastPathComponent])
    }

    @Test(arguments: [false, true])
    func directoryOrMatchingSymlinkAtLegacyNameIsPreserved(symlink: Bool) throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = "Synthetic occupied clip"
        let legacy = directory.appendingPathComponent(
            "Syntheticoccupiedclip-\(ShelfTrayDrop.stableHash(text)).txt")
        let target = directory.appendingPathComponent("external-target.txt")
        if symlink {
            try Data(text.utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: target)
        } else {
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("Synthetic directory sentinel".utf8).write(
                to: legacy.appendingPathComponent("sentinel.txt"))
        }
        let fresh = try #require(ShelfTrayDrop.textLoc(for: text, directory: directory))
        #expect(fresh != legacy)
        #expect(try String(contentsOf: fresh, encoding: .utf8) == text)
        #expect(ShelfTrayDrop.textLoc(for: text, directory: directory) == fresh)
        if symlink {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: legacy.path) == target.path)
            #expect(try String(contentsOf: target, encoding: .utf8) == text)
        } else {
            #expect(try String(contentsOf: legacy.appendingPathComponent("sentinel.txt"), encoding: .utf8)
                == "Synthetic directory sentinel")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == (symlink ? 3 : 2))
    }

    @Test func saturatedNamesReturnNilAndKeepEveryFile() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = "Synthetic saturated clip"
        let base = "Syntheticsaturatedclip-\(ShelfTrayDrop.stableHash(text))"
        var expected: [URL: Data] = [:]
        for attempt in 1...500 {
            let name = attempt == 1 ? "\(base).txt" : "\(base) \(attempt).txt"
            let url = directory.appendingPathComponent(name)
            let data = Data("Synthetic occupied candidate \(attempt)".utf8)
            try data.write(to: url)
            expected[url] = data
        }
        #expect(ShelfTrayDrop.textLoc(for: text, directory: directory) == nil)
        for (url, data) in expected {
            #expect(try Data(contentsOf: url) == data)
        }
        let contents = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(contents == Set(expected.keys.map(\.lastPathComponent)))
    }
}
