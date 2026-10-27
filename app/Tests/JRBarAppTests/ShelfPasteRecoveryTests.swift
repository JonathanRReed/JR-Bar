import JRBarTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Shelf paste recovery", .temporaryDirectory)
@MainActor
struct ShelfPasteRecoveryTests {
    @MainActor
    private final class Fixture {
        let suite = "jrbar-paste-recovery-\(UUID().uuidString)"
        let root: URL
        let defaults: UserDefaults
        let tray: ShelfTrayModel
        let board: NSPasteboard

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            tray = ShelfTrayModel(defaults: defaults)
            board = NSPasteboard(name: .init(suite))
            root = TestTemporaryDirectory.currentURL.appendingPathComponent(suite)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func acknowledgeFileThenClear() throws -> String {
            let file = root.appendingPathComponent("previous.txt")
            try Data("Synthetic previous clip".utf8).write(to: file)
            board.clearContents()
            board.writeObjects([file as NSURL])
            tray.notePasteboard(board)
            tray.paste(from: board, directory: root.appendingPathComponent("clips"))
            #expect(tray.pastedChangeCount == board.changeCount)
            let path = try #require(tray.items.first?.path)
            tray.removeAll()
            #expect(tray.canUndoClear)
            return path
        }

        func putPayload(link: Bool) -> String {
            let text = link ? "https://example.com/synthetic-recovery" : "Synthetic recoverable clip\nsecond line"
            board.clearContents()
            if link {
                board.writeObjects([NSURL(string: text)!])
            } else {
                board.setString(text, forType: .string)
            }
            return text
        }

        func boardBytes() -> [NSPasteboard.PasteboardType: Data] {
            var bytes: [NSPasteboard.PasteboardType: Data] = [:]
            for type in board.types ?? [] { bytes[type] = board.data(forType: type) }
            return bytes
        }

        func clean() {
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func failedSaveKeepsCopyAndUndoThenRetries(link: Bool, keyboard: Bool) throws {
        let f = try Fixture()
        defer { f.clean() }
        let previousPath = try f.acknowledgeFileThenClear()
        let acknowledged = f.tray.pastedChangeCount
        let payload = f.putPayload(link: link)
        f.tray.notePasteboard(f.board)
        if keyboard {
            f.tray.beginKeyboardSelection()
            #expect(f.tray.keyboardSelectionID == ShelfTrayModel.pasteKeyboardID)
        }
        let bytes = f.boardBytes()
        let count = f.board.changeCount
        let destination = f.root.appendingPathComponent("blocked-clips")
        let blocker = Data("Synthetic occupied destination".utf8)
        try blocker.write(to: destination)

        f.tray.paste(from: f.board, directory: destination)

        #expect(f.tray.pasteOffered)
        #expect(f.tray.pastedChangeCount == acknowledged)
        #expect(f.board.changeCount == count)
        #expect(f.boardBytes() == bytes)
        #expect(f.tray.entries.isEmpty)
        #expect(f.tray.canUndoClear && f.tray.clearedItemCount == 1)
        #expect(try Data(contentsOf: destination) == blocker)
        if keyboard { #expect(f.tray.keyboardSelectionID == ShelfTrayModel.pasteKeyboardID) }
        let failureNotice = try #require(f.tray.actionNotice)
        #expect(!failureNotice.isEmpty)
        f.tray.notePasteboard(f.board)
        #expect(f.tray.pasteOffered)
        f.tray.undoClear()
        #expect(f.tray.items.map(\.path) == [previousPath])
        f.tray.removeAll()
        if keyboard { f.tray.beginKeyboardSelection() }
        try FileManager.default.removeItem(at: destination)

        f.tray.paste(from: f.board, directory: destination)

        #expect(!f.tray.pasteOffered)
        #expect(f.tray.pastedChangeCount == count)
        #expect(f.board.changeCount == count)
        #expect(f.boardBytes() == bytes)
        #expect(!f.tray.canUndoClear)
        #expect(f.tray.actionNotice != failureNotice)
        let path = try #require(f.tray.items.first?.path)
        #expect(f.tray.items.count == 1)
        let generated = URL(fileURLWithPath: path)
        if link {
            let plist = try #require(NSDictionary(contentsOf: generated))
            #expect(plist["URL"] as? String == payload)
        } else {
            #expect(try String(contentsOf: generated, encoding: .utf8) == payload)
        }
        if keyboard { #expect(f.tray.keyboardSelectionID == f.tray.entries.first?.id) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 1)
        f.tray.notePasteboard(f.board)
        #expect(!f.tray.pasteOffered)

        f.board.clearContents()
        f.board.setString(payload, forType: .string)
        f.tray.notePasteboard(f.board)
        f.tray.paste(from: f.board, directory: destination)
        #expect(f.tray.items.map(\.path) == [path])
        #expect(f.tray.pastedChangeCount == f.board.changeCount)
        #expect(!f.tray.pasteOffered)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 1)
    }

    @Test(arguments: [false, true])
    func disabledShelfLeavesCopyUnacknowledgedAndCreatesNothing(link: Bool) throws {
        let f = try Fixture()
        defer { f.clean() }
        let previousPath = try f.acknowledgeFileThenClear()
        let acknowledged = f.tray.pastedChangeCount
        _ = f.putPayload(link: link)
        f.tray.notePasteboard(f.board)
        let bytes = f.boardBytes()
        let count = f.board.changeCount
        let destination = f.root.appendingPathComponent("disabled-clips")
        f.tray.shelfEnabled = { false }

        f.tray.paste(from: f.board, directory: destination)

        #expect(f.tray.pastedChangeCount == acknowledged)
        #expect(f.board.changeCount == count)
        #expect(f.boardBytes() == bytes)
        #expect(f.tray.entries.isEmpty)
        #expect(f.tray.canUndoClear && f.tray.clearedItemCount == 1)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        f.tray.shelfEnabled = { true }
        f.tray.notePasteboard(f.board)
        #expect(f.tray.pasteOffered)
        f.tray.undoClear()
        #expect(f.tray.items.map(\.path) == [previousPath])
    }

    @Test func copyArrivingDuringReadRemainsOffered() throws {
        let f = try Fixture()
        defer { f.clean() }
        let payload = f.putPayload(link: false)
        f.tray.notePasteboard(f.board)
        let originalGeneration = f.board.changeCount
        let destination = f.root.appendingPathComponent("clips")
        f.tray.paste(from: f.board, directory: destination) { board, directory in
            let result = ShelfTrayDrop.pasteResult(board, directory: directory)
            board.clearContents()
            board.setString("Synthetic newer copy", forType: .string)
            return result
        }
        #expect(f.tray.pastedChangeCount == originalGeneration)
        #expect(f.board.changeCount != originalGeneration)
        #expect(f.tray.pasteOffered)
        #expect(f.board.string(forType: .string) == "Synthetic newer copy")
        let path = try #require(f.tray.items.first?.path)
        #expect(f.tray.items.count == 1)
        #expect(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) == payload)
        f.tray.notePasteboard(f.board)
        #expect(f.tray.pasteOffered)
    }

    @Test(arguments: [0, 1, 2])
    func emptyWhitespaceAndUnsupportedCopiesAreConsumed(kind: Int) throws {
        let f = try Fixture()
        defer { f.clean() }
        let previousPath = try f.acknowledgeFileThenClear()
        f.board.clearContents()
        if kind == 1 { f.board.setString("  \n\t ", forType: .string) }
        if kind == 2 { f.board.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png) }
        f.tray.notePasteboard(f.board)
        let count = f.board.changeCount
        let bytes = f.boardBytes()
        let destination = f.root.appendingPathComponent("unused-clips")
        f.tray.actionNotice = "Synthetic unrelated action notice"

        f.tray.paste(from: f.board, directory: destination)

        #expect(f.tray.pastedChangeCount == count)
        #expect(!f.tray.pasteOffered)
        #expect(f.board.changeCount == count)
        #expect(f.boardBytes() == bytes)
        #expect(f.tray.entries.isEmpty)
        #expect(f.tray.canUndoClear)
        #expect(f.tray.actionNotice == "Synthetic unrelated action notice")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        f.tray.undoClear()
        #expect(f.tray.items.map(\.path) == [previousPath])
    }

    @Test func disabledShelfDoesNotReadTheCopy() throws {
        let f = try Fixture()
        defer { f.clean() }
        _ = f.putPayload(link: false)
        f.tray.notePasteboard(f.board)
        f.tray.shelfEnabled = { false }
        var readerCalled = false
        f.tray.paste(from: f.board, directory: f.root.appendingPathComponent("unused-clips")) { _, _ in
            readerCalled = true
            return .failed
        }
        #expect(!readerCalled)
        #expect(f.tray.pastedChangeCount == nil)
        #expect(f.tray.actionNotice == nil)
        #expect(f.tray.entries.isEmpty)
    }

    nonisolated static let renderEnabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test(.enabled(if: renderEnabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func failedPasteAndRetryRender() throws {
        let f = try Fixture()
        defer { f.clean() }
        _ = try f.acknowledgeFileThenClear()
        _ = f.putPayload(link: false)
        f.tray.notePasteboard(f.board)
        f.tray.beginKeyboardSelection()
        let destination = f.root.appendingPathComponent("blocked-clips")
        try Data("Synthetic destination blocker".utf8).write(to: destination)
        f.tray.paste(from: f.board, directory: destination)
        #expect(f.tray.canUndoClear && f.tray.pasteOffered)
        #expect(f.tray.keyboardSelectionID == ShelfTrayModel.pasteKeyboardID)
        #expect(f.tray.actionNotice != nil)

        for retried in [false, true] {
            if retried {
                try FileManager.default.removeItem(at: destination)
                f.tray.paste(from: f.board, directory: destination)
                #expect(!f.tray.pasteOffered && !f.tray.canUndoClear)
                #expect(f.tray.actionNotice == nil)
                #expect(f.tray.keyboardSelectionID == f.tray.entries.first?.id)
            }
            for dark in [false, true] {
                let row = ShelfTrayRow(tray: f.tray, style: .glass)
                    .padding(12)
                    .frame(width: 360)
                    .background(ProofGlass(cornerRadius: 16))
                let view = ZStack {
                    ProofDesktop(dark: dark)
                    row
                }
                let state = retried ? "retry" : "failed"
                let appearance = dark ? "dark" : "light"
                try ProofRender.write(view.frame(width: 440, height: 260),
                                      size: CGSize(width: 440, height: 260),
                                      name: "shelf-paste-\(state)-\(appearance)", dark: dark)
            }
        }
    }
}
