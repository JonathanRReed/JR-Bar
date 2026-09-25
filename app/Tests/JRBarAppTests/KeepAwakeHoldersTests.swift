import Foundation
import Testing
@testable import JRBarApp

/// The Keep Awake card reads macOS's power assertions off the main
/// thread and shows the last read while a new one runs.
@Suite("Keep Awake holders")
@MainActor
struct KeepAwakeHoldersTests {
    // MARK: Keep Awake

    @Test("the power assertions are read off the main thread, and the card keeps the last read")
    func keepAwakeReadsInTheBackground() async {
        let fromBackground = await Task.detached { KeepAwakeHolders.read() }.value
        let read = await KeepAwakeHolders.readInBackground()
        #expect(KeepAwakeHolders.lastRead == read)
        // Other apps come and go between the two reads; both are lists of
        // apps, never this one.
        let me = Bundle.main.bundleIdentifier
        #expect(!fromBackground.contains { $0.bundleID != nil && $0.bundleID == me })
    }
}
