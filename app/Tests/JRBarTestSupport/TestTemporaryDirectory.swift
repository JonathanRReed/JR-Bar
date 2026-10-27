import Foundation
import Testing

/// A test owns its files until its scope ends, including after a thrown assertion.
public final class TestTemporaryDirectory: Sendable {
    public let url: URL
    @TaskLocal private static var current: TestTemporaryDirectory?
    // Shared fixtures can be called from suites without our per-test trait.
    // Their files belong to the test process and are removed when it exits.
    private static let session: TestTemporaryDirectory = {
        let directory = try! TestTemporaryDirectory()
        atexit { try? TestTemporaryDirectory.session.remove() }
        return directory
    }()

    public init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    deinit { try? remove() }

    public static var currentURL: URL {
        (current ?? session).url
    }

    fileprivate static func withScope(_ body: @Sendable () async throws -> Void) async throws {
        let directory = try TestTemporaryDirectory()
        do {
            try await $current.withValue(directory, operation: body)
        } catch {
            try directory.remove()
            throw error
        }
        try directory.remove()
    }
}

public struct TemporaryDirectoryTrait: SuiteTrait, TestTrait, TestScoping {
    public var isRecursive: Bool { true }

    public func provideScope(for test: Test, testCase: Test.Case?,
                             performing function: @Sendable () async throws -> Void) async throws {
        try await TestTemporaryDirectory.withScope(function)
    }
}

extension Trait where Self == TemporaryDirectoryTrait {
    public static var temporaryDirectory: Self { Self() }
}
