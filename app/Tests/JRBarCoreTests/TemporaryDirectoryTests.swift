import Foundation
import JRBarTestSupport
import Testing
@testable import JRBarCore

@Suite("Temporary directory ownership", .temporaryDirectory)
struct TemporaryDirectoryTests {
    @Test func testDirectoryRemovesFilesOnRelease() throws {
        func create() throws -> URL {
            let directory = try TestTemporaryDirectory()
            try Data([1]).write(to: directory.url.appendingPathComponent("file"))
            return directory.url
        }
        let url = try create()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func scratchSaveKeepsItsOwnerUntilTheLastCopyIsReleased() throws {
        func makeFile() -> AquariumSaveFile {
            AquariumSaveFile(scratchDirectory: ScratchDirectory(parent: TestTemporaryDirectory.currentURL))
        }
        func create() throws -> URL {
            let copy = makeFile()
            try copy.save(AquariumSave())
            #expect(copy.exists)
            return copy.url.deletingLastPathComponent()
        }
        let url = try create()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite("Shared fixture temporary files")
struct SharedFixtureTemporaryDirectoryTests {
    @Test func aFixtureWithoutTheTraitStillHasAnOwnedDirectory() throws {
        let directory = TestTemporaryDirectory.currentURL
        let file = directory.appendingPathComponent("shared-fixture")
        try Data([1]).write(to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
        // The full-run guard checks its removal after this process exits.
    }
}
