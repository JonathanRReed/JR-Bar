import AppKit
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Shelf keyboard focus")
struct ShelfKeyboardFocusTests {
    @Test("Paste has a visible keyboard focus ring", .enabled(if: renderEnabled))
    func pasteFocusRender() throws {
        let suite = "jrbar-shelf-paste-focus-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tray = ShelfTrayModel(defaults: defaults)
        let board = NSPasteboard(name: .init(suite))
        defer { board.releaseGlobally() }
        board.writeObjects([URL(fileURLWithPath: "/tmp/synthetic-shelf-focus.txt") as NSURL])
        tray.notePasteboard(board)
        tray.beginKeyboardSelection()
        #expect(tray.keyboardSelectionID == ShelfTrayModel.pasteKeyboardID)
        for dark in [false, true] {
            let view = ZStack {
                ProofDesktop(dark: dark)
                ShelfTrayRow(tray: tray, style: .glass)
                    .padding(12)
                    .frame(width: 320)
                    .background(ProofGlass(cornerRadius: 16))
            }
            try ProofRender.write(view.frame(width: 400, height: 220),
                                  size: CGSize(width: 400, height: 220),
                                  name: "shelf-paste-focus-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    nonisolated static let renderEnabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"
    private let silentKeys = CardEscapeWatch.Source(addLocal: { _ in nil }, addGlobal: { _ in nil }, remove: { _ in })

    private func model() -> NotchCardModel {
        let defaults = UserDefaults(suiteName: "jrbar-keyboard-focus-\(UUID().uuidString)")!
        return NotchCardModel(
            timers: ShelfTimerModel(storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("jrbar-keyboard-timer-\(UUID().uuidString).json")),
            tray: ShelfTrayModel(defaults: defaults), runtimeEnabled: false)
    }

    private func toy() -> (NotchToy, ToysStore) {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: model(), notchRuntimeEnabled: false)
        store.notch.islandVisible = true
        return (store.notch, store)
    }

    private func glass() -> NotchCardPresenter {
        let presenter = NotchCardPresenter(model: model())
        presenter.presentationEnabled = false
        presenter.surface = { .glass }
        presenter.anchor = { CGRect(x: 100, y: 100, width: 200, height: 20) }
        presenter.keySource = silentKeys
        return presenter
    }

    @Test("the explicit island command engages Shelf; Escape returns focus without folding")
    func islandEscape() {
        let (toy, store) = toy()
        defer { toy.collapseIsland(); withExtendedLifetime(store) {} }
        toy.askKeyboardEngaged = true
        #expect(toy.useShelfKeyboard() == nil)
        #expect(toy.islandExpanded && toy.shelfKeyboardEngaged)
        #expect(!toy.askKeyboardEngaged)
        #expect(toy.cardModel.page == .shelf)
        toy.shelfKey(.escape)
        #expect(!toy.shelfKeyboardEngaged)
        #expect(toy.islandExpanded)
    }

    @Test("page changes and collapse release island keyboard ownership")
    func islandRelease() {
        let (toy, store) = toy()
        defer { toy.collapseIsland(); withExtendedLifetime(store) {} }
        #expect(toy.useShelfKeyboard() == nil)
        toy.cardModel.show(.now)
        #expect(!toy.shelfKeyboardEngaged)
        #expect(toy.useShelfKeyboard() == nil)
        toy.collapseIsland()
        #expect(!toy.shelfKeyboardEngaged)
    }

    @Test("ordinary hover and drop-target commands never engage the keyboard")
    func existingSummonStaysNonKey() {
        let (toy, store) = toy()
        defer { toy.collapseIsland(); withExtendedLifetime(store) {} }
        #expect(toy.toggleShelf() == nil)
        #expect(!toy.shelfKeyboardEngaged)
        toy.collapseIsland()
        toy.expand(held: false)
        #expect(!toy.shelfKeyboardEngaged)
    }

    @Test("glass Shelf opens without an agent and Escape releases focus without closing")
    func glassEscape() {
        let presenter = glass()
        defer { presenter.hide() }
        #expect(!presenter.panel.canBecomeKey)
        #expect(presenter.useShelfKeyboard() == nil)
        #expect(presenter.isShown && presenter.isPinned && presenter.shelfKeyboardEngaged)
        #expect(presenter.panel.canBecomeKey)
        presenter.shelfKey(.escape)
        #expect(!presenter.shelfKeyboardEngaged && !presenter.panel.canBecomeKey)
        #expect(presenter.isShown)
    }

    @Test("glass page changes, focus loss and hide release keyboard ownership")
    func glassRelease() {
        let presenter = glass()
        defer { presenter.hide() }
        #expect(presenter.useShelfKeyboard() == nil)
        presenter.model.show(.now)
        #expect(!presenter.shelfKeyboardEngaged)
        #expect(presenter.useShelfKeyboard() == nil)
        presenter.panel.resignKey()
        #expect(!presenter.shelfKeyboardEngaged)
        #expect(presenter.useShelfKeyboard() == nil)
        presenter.hide()
        #expect(!presenter.shelfKeyboardEngaged && !presenter.panel.canBecomeKey)
    }

    @Test("an unavailable glass anchor refuses without retaining focus or a pin")
    func noAnchor() {
        let presenter = glass()
        defer { presenter.hide() }
        presenter.anchor = { nil }
        #expect(presenter.useShelfKeyboard() != nil)
        #expect(!presenter.shelfKeyboardEngaged && !presenter.isPinned)
    }

    @Test("the disabled Shelf refuses before engaging keyboard ownership")
    func disabled() {
        let (toy, store) = toy()
        defer { withExtendedLifetime(store) {} }
        store.state.notch.shelfEnabled = false
        #expect(toy.useShelfKeyboard() != nil)
        #expect(!toy.shelfKeyboardEngaged)
    }

    @Test("disabling Shelf releases glass ownership before another selection move")
    func glassDisabled() {
        let presenter = glass()
        defer { presenter.hide() }
        #expect(presenter.useShelfKeyboard() == nil)
        presenter.model.tray.shelfEnabled = { false }
        presenter.shelfKey(.right)
        #expect(!presenter.shelfKeyboardEngaged && !presenter.panel.canBecomeKey)
        #expect(presenter.useShelfKeyboard() != nil)
    }

    @Test("Space never opens a file; Return and arrow keys are explicit")
    func keyMapping() {
        #expect(ShelfKeyboardInput.key(code: 49, shift: false) == .other)
        #expect(ShelfKeyboardInput.key(code: 36, shift: false) == .activate)
        #expect(ShelfKeyboardInput.key(code: 53, shift: false) == .escape)
        #expect(ShelfKeyboardInput.key(code: 123, shift: false) == .left)
    }

    @Test("modifier chords belong to AppKit and accessibility rather than Shelf or ask navigation")
    func modifierOwnership() {
        let modified: [NSEvent.ModifierFlags] = [.command, .control, .option, [.control, .option], [.command, .shift]]
        for modifiers in modified {
            #expect(!ShelfKeyboardInput.claims(modifiers: modifiers))
        }
        let ordinary: [NSEvent.ModifierFlags] = [[], .shift, .capsLock, .function, .numericPad]
        for modifiers in ordinary {
            #expect(ShelfKeyboardInput.claims(modifiers: modifiers))
        }
    }

    @Test(.enabled(if: renderEnabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func selectedTileRender() throws {
        let suite = "jrbar-keyboard-render-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let tray = ShelfTrayModel(defaults: defaults)
        for index in 0..<12 {
            let folder = root.appendingPathComponent("\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("file-\(index).txt")
            try Data("Synthetic fixture".utf8).write(to: file)
            tray.add([file])
        }
        tray.beginKeyboardSelection()
        tray.moveKeyboardSelection(by: 10)
        #expect(tray.keyboardSelectionID == tray.entries[10].id)
        for dark in [false, true] {
            let view = ZStack {
                ProofDesktop(dark: dark)
                ShelfTrayRow(tray: tray, style: .glass)
                    .padding(12)
                    .frame(width: 320)
                    .background(ProofGlass(cornerRadius: 16))
            }
            try ProofRender.write(view.frame(width: 400, height: 220),
                                  size: CGSize(width: 400, height: 220),
                                  name: "shelf-keyboard-\(dark ? "dark" : "light")", dark: dark)
        }
    }
}
