import JRBarTestSupport
import Foundation
import Testing
@testable import JRBarCore

/// The bearer token the loopback endpoint requires lives in the state
/// directory. A file somebody else left there is not trusted: a link is
/// not followed and a file others can read is not reused.
@Suite(.temporaryDirectory)
struct ServeTokenTests {
    private func scratch() throws -> String {
        let directory = (TestTemporaryDirectory.currentURL.path + "/") + "jrbar-serve-token-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func mode(_ path: String) throws -> Int {
        var info = stat()
        #expect(lstat(path, &info) == 0)
        return Int(info.st_mode & 0o7777)
    }

    @Test func aFirstUseWritesAPrivateTokenAndLaterUsesReadItBack() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/serve-token"
        let first = try #require(ServeToken.load(at: path))
        #expect(first.count >= 24)
        #expect(try mode(path) == 0o600)
        #expect(ServeToken.load(at: path) == first)
    }

    @Test func aLinkInThePlaceOfTheTokenIsNotFollowed() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let elsewhere = directory + "/elsewhere"
        let planted = String(repeating: "a", count: 40)
        try Data(planted.utf8).write(to: URL(fileURLWithPath: elsewhere))
        chmod(elsewhere, 0o600)
        let path = directory + "/serve-token"
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: elsewhere)
        let token = try #require(ServeToken.load(at: path))
        #expect(token != planted, "a token behind a link is not the token")
        #expect(try String(contentsOfFile: elsewhere, encoding: .utf8) == planted, "the link's target is left alone")
        #expect(try mode(path) == 0o600, "the path is now a private regular file")
    }

    @Test func aTokenFileOthersCanReadIsReplaced() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/serve-token"
        let loose = String(repeating: "b", count: 40)
        try Data(loose.utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, 0o644)
        let token = try #require(ServeToken.load(at: path))
        #expect(token != loose)
        #expect(try mode(path) == 0o600)
    }
}
