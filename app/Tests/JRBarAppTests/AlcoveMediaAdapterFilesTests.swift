import Foundation
import Testing
@testable import JRBarApp

/// The Now Playing helper's dylib sits in a private folder, is checked
/// against its pinned hash before perl loads it, and the copies older
/// builds left in the temporary folder are removed. All of it runs in a
/// scratch folder.
@Suite struct AlcoveMediaAdapterFilesTests {
    private static let payload = Data("synthetic dylib bytes".utf8)

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-alcove-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func files(in root: URL, bytes: Data = payload, sha256: String? = nil) -> AlcoveMediaAdapterFiles {
        AlcoveMediaAdapterFiles(
            directory: root.appendingPathComponent("support/Alcove", isDirectory: true),
            legacyDirectories: [root.appendingPathComponent("tmp/jrbar-alcove", isDirectory: true)],
            bytes: bytes,
            sha256: sha256 ?? AlcoveMediaAdapterFiles.hex(bytes))
    }

    private func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.flatMap { $0.intValue }
    }

    @Test func theShippedBytesHashToThePinnedValue() throws {
        let bytes = try #require(Data(base64Encoded: AlcoveMediaAdapterAsset.dylibBase64))
        #expect(AlcoveMediaAdapterFiles.hex(bytes) == AlcoveMediaAdapterAsset.dylibSHA256)
    }

    @Test func theCopyIsWrittenReadOnlyInAFolderOnlyWeCanEnter() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = files(in: root)
        let url = try adapter.prepare()
        #expect(url == adapter.fileURL)
        #expect(try Data(contentsOf: url) == Self.payload)
        #expect(mode(url) == 0o500)
        #expect(mode(adapter.directory) == 0o700)
    }

    @Test func aLooseFolderIsTightenedToPrivate() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = files(in: root)
        try FileManager.default.createDirectory(
            at: adapter.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        _ = try adapter.prepare()
        #expect(mode(adapter.directory) == 0o700)
    }

    @Test func aTamperedCopyIsReplacedBeforeItIsHanded_over() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = files(in: root)
        let url = try adapter.prepare()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try Data("not the helper".utf8).write(to: url)
        let again = try adapter.prepare()
        #expect(again == url)
        #expect(try Data(contentsOf: again) == Self.payload)
    }

    @Test func bytesThatDoNotMatchThePinAreNeverWritten() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = files(in: root, sha256: String(repeating: "0", count: 64))
        #expect(throws: AlcoveMediaAdapterFiles.Failure.embeddedBytesMismatch) { try adapter.prepare() }
        #expect(!FileManager.default.fileExists(atPath: adapter.fileURL.path))
    }

    @Test func staleCopiesHereAndInTheOldTemporaryFolderAreRemoved() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = files(in: root)
        let legacy = try #require(adapter.legacyDirectories.first)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: legacy.appendingPathComponent("mediaremote-0123456789abcdef.dylib"))
        try FileManager.default.createDirectory(at: adapter.directory, withIntermediateDirectories: true)
        let older = adapter.directory.appendingPathComponent("mediaremote-ffffffffffffffff.dylib")
        try Data("older".utf8).write(to: older)

        let url = try adapter.prepare()

        #expect(!FileManager.default.fileExists(atPath: older.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: adapter.directory.path)
                == [url.lastPathComponent])
    }

    @Test func aLegacyFolderHoldingOtherFilesIsKept() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = files(in: root)
        let legacy = try #require(adapter.legacyDirectories.first)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let other = legacy.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: other)
        _ = try adapter.prepare()
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func aLinkInPlaceOfTheFolderIsRefused() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = files(in: root)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: adapter.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: adapter.directory, withDestinationURL: elsewhere)
        #expect(throws: AlcoveMediaAdapterFiles.Failure.folderNotPrivate) { try adapter.prepare() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }
}
