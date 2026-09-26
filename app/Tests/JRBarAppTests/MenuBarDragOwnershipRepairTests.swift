import AppKit
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Menu Bar drag ownership repairs")
@MainActor
struct MenuBarDragOwnershipRepairTests {
    @MainActor private final class Backend: MenuBarConcealBackend {
        func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
            MenuBarAssertionToken(NSNumber(value: 1))
        }
        func invalidate(_ token: MenuBarAssertionToken) {}
    }

    @MainActor private final class ReadGate {
        var started = false
        var entered: CheckedContinuation<Void, Never>?
        var read: CheckedContinuation<[MenuBarItem]?, Never>?
        func waitUntilReading() async {
            if started { return }
            await withCheckedContinuation { entered = $0 }
        }
        func listing() async -> [MenuBarItem]? {
            started = true
            entered?.resume(); entered = nil
            return await withCheckedContinuation { read = $0 }
        }
        func finish(_ items: [MenuBarItem]) {
            read?.resume(returning: items); read = nil
        }
    }

    @MainActor private final class Harness {
        let utility = MenuBarUtility(runningBundleIDRead: { [] })
        let gate = ReadGate()
        var settings = MenuBarSettings(enabled: true, concealSeeded: true)
        var writes = 0
        var rows = [MenuBarDragLearnTests.row]
        let before = MenuBarDragLearnTests.bar()
        var after: [MenuBarItem] {
            MenuBarDragLearnTests.moved("Tailscale", to: 1045, in: before)
        }
        init() {
            utility.settings = { [unowned self] in settings }
            utility.onSettingsChange = { [unowned self] in settings = $0; writes += 1 }
            utility.concealer = MenuBarConcealer(backend: Backend())
            utility.concealerStartedAt = .distantPast
            utility.dragListing = { [unowned self] in before }
            utility.dragFreshListing = { [gate = self.gate] _ in await gate.listing() }
            utility.dragRows = { [unowned self] in rows }
            utility.dragIconSpan = { MenuBarDragLearnTests.icon }
            utility.dragSettle = 0
            utility.dragUnfreezeDelay = 0
            utility.presentDropNote = { _ in }
            utility.hider.listItems = { [unowned self] in before }
            utility.hider.rowRect = { MenuBarDragLearnTests.row }
            utility.hider.shuttersSuppressed = true
        }
        func release() {
            utility.commandPressed(at: CGPoint(x: 1131, y: 18))
            utility.commandReleased(at: CGPoint(x: 1000, y: 18), option: false)
        }
    }

    @Test(arguments: ["cancel", "new gesture", "disabled", "new engine", "new display", "sleep"])
    func obsoleteConfirmationCannotWrite(interruption: String) async throws {
        let h = Harness()
        h.release()
        let oldTask = try #require(h.utility.dragConfirmTask)
        await h.gate.waitUntilReading()
        switch interruption {
        case "cancel": oldTask.cancel()
        case "new gesture": h.utility.commandPressed(at: CGPoint(x: 1165, y: 18))
        case "disabled": h.settings.enabled = false
        case "new engine": h.utility.concealer = MenuBarConcealer(backend: Backend())
        case "new display": h.rows.append(CGRect(x: -1920, y: 0, width: 1920, height: 24))
        case "sleep": h.utility.dragInFlight?.environment?.invalidate()
        default: Issue.record("unknown test case")
        }
        let successor = h.utility.dragInFlight?.id
        h.gate.finish(h.after)
        await oldTask.value
        #expect(h.writes == 0)
        if interruption == "new gesture" {
            #expect(h.utility.dragInFlight?.id == successor)
            #expect(h.utility.dragFrozen, "an old completion must not thaw its successor")
        }
        h.utility.cancelDrag()
        #expect(!h.utility.dragFrozen)
    }

    @Test func acceptedGestureCommitsOnlyOnce() async throws {
        let h = Harness()
        h.release()
        let task = try #require(h.utility.dragConfirmTask)
        await h.gate.waitUntilReading()
        h.utility.commandReleased(at: CGPoint(x: 1000, y: 18), option: false)
        h.gate.finish(h.after)
        await task.value
        #expect(h.writes == 1)
        #expect(h.settings.concealedApps[MenuBarDragLearnTests.tailscaleID] == .hidden)
        #expect(!h.utility.dragFrozen)
        #expect(h.utility.dragInFlight == nil)
    }

    @Test func environmentInvalidatesOnceAndStopsObservingAfterFinish() {
        let workspace = NotificationCenter()
        let application = NotificationCenter()
        let gesture = MenuBarDragEnvironment(workspace: workspace, application: application)
        var cancellations = 0
        gesture.onInvalidation = { cancellations += 1 }
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(!gesture.isValid)
        #expect(cancellations == 1)
        let finished = MenuBarDragEnvironment(workspace: workspace, application: application)
        finished.onInvalidation = { cancellations += 1 }
        finished.finish()
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(cancellations == 1)
    }
}
