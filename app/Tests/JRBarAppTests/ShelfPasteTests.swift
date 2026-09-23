import AppKit
import Foundation
import Testing
@testable import JRBarApp

/// The shelf's Paste chip: offered for what the shelf can take, read by
/// types alone until the click, and never offered twice for one copy.
/// A private named pasteboard stands in for the general one.
@Suite("Shelf paste")
@MainActor
struct ShelfPasteTests {
    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("jrbar.test.\(UUID().uuidString)"))
    }

    @Test("files, links and text are shelf-able; an image alone is not")
    func shelfable() {
        #expect(ShelfTrayDrop.hasShelfable([.fileURL]))
        #expect(ShelfTrayDrop.hasShelfable([.URL]))
        #expect(ShelfTrayDrop.hasShelfable([.string]))
        #expect(!ShelfTrayDrop.hasShelfable([.png, .tiff]))
        #expect(!ShelfTrayDrop.hasShelfable([]))
    }

    @Test("copied files paste as themselves")
    func files() {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let a = URL(fileURLWithPath: "/tmp/jrbar-paste/a.png")
        let b = URL(fileURLWithPath: "/tmp/jrbar-paste/b.txt")
        board.clearContents()
        board.writeObjects([a as NSURL, b as NSURL])
        #expect(ShelfTrayDrop.pasteURLs(board).map(\.path) == [a.path, b.path])
    }

    @Test("the chip shows for a fresh copy and not for an empty or unshelvable one")
    func offered() {
        let tray = ShelfTrayModel()
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        board.clearContents()
        tray.notePasteboard(board)
        #expect(!tray.pasteOffered, "nothing copied, nothing offered")
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/jrbar-paste/a.png") as NSURL])
        tray.notePasteboard(board)
        #expect(tray.pasteOffered)
        board.clearContents()
        board.setData(Data([0x89, 0x50]), forType: .png)
        tray.notePasteboard(board)
        #expect(!tray.pasteOffered, "an image with no file is not the shelf's")
    }
}
