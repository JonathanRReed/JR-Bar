import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The roaming half of the Notch Buddy: parking it free writes
/// `freePosition` and re-lays the panels, tucking it away flips `isOn`
/// until the next event or a card re-enable, the menu carries the whole
/// pet's business, and the carry's bookkeeping feeds the view's dangle.
/// `CoreModel` without a daemon has no sessions, so the menu's
/// conditional "Open" item is only ever absent here.
@Suite("Buddy roaming")
@MainActor
struct BuddyRoamingTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeToy(state: ToysState = ToysState()) -> (NotchBuddyToy, ToysStore) {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state)
        return (store.notchBuddy, store)
    }

    @Test("docked by default; parking writes the spot and re-lays the panels")
    func parkAndDock() {
        let (toy, store) = makeToy()
        var syncs = 0
        toy.onVisibilityChange = { syncs += 1 }
        #expect(toy.isFree == false)
        #expect(toy.freeSpot == nil)

        toy.parkFree(at: CGPoint(x: 120, y: 700))
        #expect(store.state.notchBuddy.freePosition == BuddySpot(x: 120, y: 700))
        #expect(toy.isFree == true)
        #expect(syncs == 1)

        toy.dock()
        #expect(store.state.notchBuddy.freePosition == nil)
        #expect(toy.isFree == false)
        #expect(syncs == 2)
    }

    @Test("tucked is hidden until re-enabled; the card toggle is the re-enable")
    func tuckAway() {
        let (toy, store) = makeToy()
        toy.isOn = true
        #expect(toy.isOn == true)
        #expect(toy.status == .on)

        toy.tuckAway()
        #expect(store.state.notchBuddy.tucked == true)
        #expect(store.state.notchBuddy.enabled == true, "a nap, not a farewell")
        #expect(toy.isOn == false)
        #expect(toy.status == .paused("Tucked away"))

        toy.isOn = true
        #expect(toy.isOn == true)
        #expect(store.state.notchBuddy.tucked == false)
    }

    @Test("the caption flag persists and re-lays the panel")
    func captionToggle() {
        let (toy, store) = makeToy()
        var syncs = 0
        toy.onVisibilityChange = { syncs += 1 }
        #expect(toy.showsCaption == true)
        toy.toggleCaption()
        #expect(store.state.notchBuddy.showCaption == false)
        #expect(toy.showsCaption == false)
        #expect(syncs == 1)
        toy.toggleCaption()
        #expect(toy.showsCaption == true)
    }

    @Test("the size dial writes the settings and re-lays the floating panel live")
    func scaleDial() {
        let (toy, store) = makeToy()
        var syncs = 0
        toy.onVisibilityChange = { syncs += 1 }
        #expect(toy.buddyScale == 1)
        toy.scaleBinding.wrappedValue = 2
        #expect(store.state.notchBuddy.scale == 2)
        #expect(toy.buddyScale == 2)
        #expect(syncs == 1)
        // A hand-edited state can't grow a screen-eating pet either.
        store.state.notchBuddy.scale = 12
        #expect(toy.buddyScale == 3)
        toy.scaleBinding.wrappedValue = 0.5
        #expect(store.state.notchBuddy.scale == 1)
    }

    @Test("with nothing on the clock the caption is the name tag")
    func captionFallback() {
        let (toy, store) = makeToy()
        #expect(toy.caption(at: t0) == "Dot")
        store.state.notchBuddy.buddyName = "Gribble"
        #expect(toy.caption(at: t0) == "Gribble")
    }

    @Test("the menu carries the pet's business: pet, treat, rename, roster, float, caption, tuck")
    func menuContents() {
        // The store is weak-held by the toy — keep it in scope.
        let (toy, store) = makeToy()
        _ = store
        let menu = toy.actionMenu(panelFrame: NSRect(x: 100, y: 500, width: 40, height: 30))
        let titles = menu.items.map(\.title)
        #expect(titles[0] == "Pet it")
        #expect(titles[1] == "Give treat")
        #expect(titles[2] == "Rename…")
        #expect(titles[3] == "Change character")
        #expect(titles.contains("Float free"))
        #expect(titles.contains("Show caption"))
        #expect(titles.last == "Tuck away")
        #expect(!titles.contains { $0.hasPrefix("Open") },
                "no ask is open — no session to open")
        // The roster submenu is the full cast, the current one ticked.
        let roster = menu.items[3].submenu
        #expect(roster?.items.count == BuddyCharacter.allCases.count)
        #expect(roster?.items.filter { $0.state == .on }.map(\.title) == ["Dot"])
        #expect(menu.items.first { $0.title == "Show caption" }?.state == .on)
    }

    @Test("the menu's dock line flips with where the buddy lives")
    func menuDockLine() {
        let (toy, store) = makeToy()
        _ = store
        let frame = NSRect(x: 300, y: 600, width: 40, height: 30)
        #expect(toy.actionMenu(panelFrame: frame).items.contains { $0.title == "Float free" })
        toy.parkFree(at: CGPoint(x: 300, y: 600))
        #expect(toy.actionMenu(panelFrame: frame).items.contains { $0.title == "Dock at the notch" })
    }

    @Test("menu actions act: pet counts, float free parks at the pill's centre")
    func menuActionsAct() {
        let (toy, store) = makeToy()
        let frame = NSRect(x: 300, y: 600, width: 40, height: 30)
        let menu = toy.actionMenu(panelFrame: frame)
        let pet = try! #require(menu.items.first { $0.title == "Pet it" })
        let actions = try! #require(pet.target as? BuddyMenuActions)
        actions.pet(pet)
        #expect(store.state.notchBuddy.care.petCount == 1)

        let float = try! #require(menu.items.first { $0.title == "Float free" })
        actions.toggleDock(float)
        #expect(store.state.notchBuddy.freePosition == BuddySpot(x: 320, y: 615),
                "float free parks it where the pill was")

        let roster = try! #require(menu.items[3].submenu)
        let crab = try! #require(roster.items.first { $0.title == "Crab" })
        actions.pickCharacter(crab)
        #expect(store.state.notchBuddy.character == "crab")
    }

    @Test("the carry's bookkeeping feeds the dangle and the landing beat")
    func dragLifecycle() {
        let (toy, _) = makeToy()
        toy.dragStarted()
        #expect(toy.isDragged == true)
        toy.dragMoved(dx: 30, at: t0)
        #expect(toy.dragTilt == BuddyPlacement.dragTilt(dx: 30))
        #expect(toy.dragMovedAt == t0)
        toy.dragEnded(at: t0)
        #expect(toy.isDragged == false)
        #expect(toy.dragTilt == 0)
        #expect(toy.landedAt == t0)
        toy.dragStarted()
        toy.dragCancelled()
        #expect(toy.isDragged == false)
        #expect(toy.landedAt == nil, "a cancelled carry is no landing")
    }
}
