import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// What's New: the catalog's shape, the gate that decides when the
/// window comes up on its own, and the stamp that keeps it to once per
/// release. Nothing here shows a window or runs a real command.
@MainActor
@Suite struct WhatsNewTests {
    final class Log {
        var stamped: [String] = []
        var ran: [AppCommand] = []
    }

    // MARK: The catalog

    @Test func entriesAreFewUniqueAndShort() {
        let entries = WhatsNewCatalog.entries
        #expect(!entries.isEmpty)
        #expect(entries.count <= WhatsNewCatalog.maximumRows)
        #expect(Set(entries.map(\.id)).count == entries.count, "ids are stable keys and must not repeat")
        for entry in entries {
            #expect(entry.title.split(separator: " ").count <= 5, "\(entry.id): a title is five words at most")
            #expect(entry.detail.hasSuffix("."), "\(entry.id): the detail is a sentence")
            #expect(!entry.detail.dropLast().contains(". "), "\(entry.id): one sentence, not two")
            #expect(NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil) != nil,
                    "\(entry.id): \(entry.symbol) is an SF Symbol")
            #expect((entry.tryIt == nil) == (entry.opens == nil),
                    "\(entry.id): a Try it says what it opens, and only a Try it does")
        }
    }

    @Test func everyTryItIsALinkThatReadsBackAsItself() {
        let commands = WhatsNewCatalog.entries.compactMap(\.tryIt)
        #expect(!commands.isEmpty)
        for command in commands {
            #expect(AppCommand.parse(command.link) == command, "\(command.link.absoluteString)")
        }
    }

    @Test func noTryItAnswersAnAgentOrTouchesTheWire() {
        // Opening surfaces only: the router has no verb that answers an
        // ask, and none of these reaches past the Mac.
        for command in WhatsNewCatalog.entries.compactMap(\.tryIt) {
            switch command {
            case .menuBar(.commandBar), .panel(toggle: false), .settings, .window, .shelf,
                 .overviewGraph, .aquarium: continue
            default: Issue.record("\(command) is not a surface to open")
            }
        }
    }

    @Test func theGraphAndTheAquariumRowsOpenTheThingItself() {
        let graphRow = WhatsNewCatalog.entries.first { $0.id == "graph" }
        let tankRow = WhatsNewCatalog.entries.first { $0.id == "aquarium" }
        #expect(graphRow?.tryIt == .overviewGraph)
        #expect(graphRow?.opens == "Opens the Overview's Graph")
        #expect(tankRow?.tryIt == .aquarium)
        #expect(tankRow?.opens == "Opens the Aquarium")
    }

    // MARK: The gate

    @Test func theWindowIsOwedOnlyAfterSetupAndOncePerRelease() {
        let release = WhatsNewCatalog.releaseID
        #expect(WhatsNewGate.isArmed(setupFinished: true, setupShownThisLaunch: false, seen: nil))
        #expect(WhatsNewGate.isArmed(setupFinished: true, setupShownThisLaunch: false, seen: "2026-01-01"))
        #expect(!WhatsNewGate.isArmed(setupFinished: false, setupShownThisLaunch: false, seen: nil),
                "Setup unfinished: its own walkthrough comes first")
        #expect(!WhatsNewGate.isArmed(setupFinished: true, setupShownThisLaunch: true, seen: nil),
                "never in the same launch as Setup")
        #expect(!WhatsNewGate.isArmed(setupFinished: true, setupShownThisLaunch: false, seen: release),
                "already seen")
    }

    @Test func itWaitsForALiveCoreAnUnlockedSessionAndNoFullScreen() {
        let right = WhatsNewGate.Moment(coreLive: true, locked: false, fullScreenInFront: false)
        #expect(WhatsNewGate.isRight(right))
        var offline = right
        offline.coreLive = false
        #expect(!WhatsNewGate.isRight(offline), "core offline")
        var locked = right
        locked.locked = true
        #expect(!WhatsNewGate.isRight(locked), "locked")
        var fullScreen = right
        fullScreen.fullScreenInFront = true
        #expect(!WhatsNewGate.isRight(fullScreen), "full screen in front")
    }

    // MARK: The window

    @Test func closingStampsTheReleaseAndLetsGoOfTheCard() async {
        let log = Log()
        let controller = WhatsNewWindowController()
        controller.markSeen = { log.stamped.append($0) }
        let window = WindowContentLifecycleTests.window(resizable: false)
        weak var card: NSViewController?
        autoreleasepool {
            let attached = controller.attachContent(to: window)
            attached.view.layoutSubtreeIfNeeded()
            card = attached
            #expect(window.title == "What's New in JR-Bar")
        }
        autoreleasepool {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        }
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(log.stamped == [WhatsNewCatalog.releaseID], "any close counts as seen")
        #expect(window.contentViewController == nil)
        #expect(card == nil)
        #expect(!controller.isArmed, "a close ends the wait for the automatic showing")
    }

    @Test func aRefusedTryItIsSaidOnItsRow() {
        let log = Log()
        let controller = WhatsNewWindowController()
        controller.run = { command in
            log.ran.append(command)
            return command == .shelf ? .refused("JR-Bar is still starting.") : .done
        }
        #expect(controller.tryIt(.window(.usage)) == nil)
        #expect(controller.tryIt(.shelf) == "JR-Bar is still starting.")
        #expect(log.ran == [.window(.usage), .shelf])
    }

    @Test func theCardIsSizedToItsRows() {
        let hosting = NSHostingController(rootView: WhatsNewView(
            entries: WhatsNewCatalog.entries, tryIt: { _ in nil }, onDone: {}))
        let size = WhatsNewWindowController.contentSize(of: hosting)
        #expect(size.width == WhatsNewView.width)
        #expect(size.height > 400, "eight rows, a header and Done: \(size.height)")
        #expect(size.height < 760, "the card fits a laptop screen: \(size.height)")
        #expect(WhatsNewView.versionLine(bundle: Bundle(for: WhatsNewWindowController.self)).isEmpty == false)
    }

    @Test func theWindowIsAsTallAsTheCardAndStaysSoAcrossAReopen() {
        let controller = WhatsNewWindowController()
        let measured = WhatsNewWindowController.contentSize(of: NSHostingController(rootView: WhatsNewView(
            entries: WhatsNewCatalog.entries, tryIt: { _ in nil }, onDone: {})))
        let window = controller.makeWindow()
        defer { WindowContentLifecycle.detach(from: window) }
        #expect(!window.isVisible, "built, not shown")
        #expect(measured.height != 560, "the card is not the window's first guess, or this proves nothing")
        #expect(window.contentRect(forFrameRect: window.frame).size == measured,
                "the whole card shows: header, rows and Done")
        #expect(window.contentView?.frame.size == measured, "the plate fills the window")

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        #expect(window.contentViewController == nil)
        controller.attachContent(to: window)
        #expect(window.contentRect(forFrameRect: window.frame).size == measured, "a reopen keeps the card's height")
        #expect(window.contentView?.frame.size == measured)
    }

    // MARK: The stamp in setup.json

    @Test func whatsNewSeenDecodesTolerantly() throws {
        let decoded = try JSONDecoder().decode(SetupState.self, from: Data(#"{"whatsNewSeen":"2026-09-24"}"#.utf8))
        #expect(decoded.whatsNewSeen == "2026-09-24")
        let wrongType = try JSONDecoder().decode(SetupState.self, from: Data(#"{"whatsNewSeen":7,"presentedCount":1}"#.utf8))
        #expect(wrongType.whatsNewSeen == nil)
        #expect(wrongType.presentedCount == 1, "one bad key leaves the rest")
        let older = try JSONDecoder().decode(SetupState.self, from: Data(#"{"finishedAt":100}"#.utf8))
        #expect(older.whatsNewSeen == nil, "a setup.json from before What's New reads as not seen")
        let state = SetupState(finishedAt: 100, whatsNewSeen: "r1")
        #expect(try JSONDecoder().decode(SetupState.self, from: JSONEncoder().encode(state)) == state)
    }

    @Test func aFirstFinishCountsThisReleaseAsSeen() {
        var persisted: [SetupState] = []
        let store = SetupStore(model: SetupModel(), load: { SetupState() }, persist: { persisted.append($0) })
        store.finish()
        #expect(store.whatsNewSeen == WhatsNewCatalog.releaseID,
                "someone new has nothing to catch up on")
        #expect(persisted.last?.whatsNewSeen == WhatsNewCatalog.releaseID)

        // A Mac that finished Setup before What's New existed still owes it.
        let earlier = SetupStore(model: SetupModel(), load: { SetupState(finishedAt: 100) }, persist: { _ in })
        earlier.finish()
        #expect(earlier.whatsNewSeen == nil)
        #expect(WhatsNewGate.isArmed(setupFinished: earlier.hasFinished, setupShownThisLaunch: false,
                                     seen: earlier.whatsNewSeen))
    }

    @Test func markingSeenKeepsTheLastRunsOutcomes() {
        var persisted: [SetupState] = []
        let loaded = SetupState(completedSteps: ["welcome", "agents"], finishedAt: 100, presentedCount: 1)
        let store = SetupStore(model: SetupModel(), load: { loaded }, persist: { persisted.append($0) })
        store.markWhatsNewSeen("r1")
        #expect(persisted.count == 1)
        #expect(persisted.last?.whatsNewSeen == "r1")
        #expect(persisted.last?.completedSteps == ["welcome", "agents"])
        store.markWhatsNewSeen("r1")
        #expect(persisted.count == 1, "the same release twice writes nothing")
    }
}
