import AppKit
import JRBarCore

@MainActor
enum ShelfKeyboardInput {
    static func claims(modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .control, .option]).isEmpty
    }

    static func key(code: UInt16, shift: Bool) -> NotchAskFocus.Key {
        // Space belongs to controls; opening a file requires Return.
        code == 49 ? .other : NotchAskFocus.key(forKeyCode: code, shift: shift)
    }

    static func handle(_ key: NotchAskFocus.Key, tray: ShelfTrayModel, pasteboard: NSPasteboard? = nil) {
        switch key {
        case .left: tray.moveKeyboardSelection(column: -1, row: 0)
        case .right: tray.moveKeyboardSelection(column: 1, row: 0)
        case .up: tray.moveKeyboardSelection(column: 0, row: -1)
        case .down: tray.moveKeyboardSelection(column: 0, row: 1)
        case .backTab: tray.moveKeyboardSelection(by: -1)
        case .tab: tray.moveKeyboardSelection(by: 1)
        case .activate:
            if tray.keyboardSelectionID == ShelfTrayModel.pasteKeyboardID {
                guard tray.pasteOffered else { tray.beginKeyboardSelection(); return }
                tray.paste(from: pasteboard ?? .general)
            } else {
                _ = tray.openKeyboardSelection()
            }
        case .escape, .space, .other: break
        }
    }
}

extension NotchToy {
    @discardableResult
    func useShelfKeyboard() -> String? {
        guard settings.shelfEnabled else { return "Turn on Shelf in Notch settings first." }
        guard !foldEngaged else { return "Close the Fold preview before using Shelf." }
        releaseAskKeyboard()
        releaseShelfKeyboard()
        switch notchSurface {
        case .island:
            releaseGlassShelfKeyboard()
            if activeOverlay != nil { endOverlay(settle: false) }
            if let capsule = activeCapsule {
                shelvedCapsule = (capsule, capsuleClock())
                activeCapsule = nil
                capsuleWork?.cancel()
                capsuleWork = nil
            }
            cardModel.show(.shelf)
            expand(held: true)
            guard islandExpanded else { return "The Shelf card could not open." }
            cardModel.tray.beginKeyboardSelection()
            shelfKeyboardEngaged = true
            syncCardKeyMonitors()
            island?.takeKeyboard()
            return nil
        case .glass:
            return useGlassShelfKeyboard()
        case .none:
            return "The Notch utility is off — turn it on in Utilities."
        }
    }

    func releaseShelfKeyboard() {
        guard shelfKeyboardEngaged else { return }
        shelfKeyboardEngaged = false
        cardModel.tray.endKeyboardSelection()
        island?.returnKeyboard()
        syncCardKeyMonitors()
    }

    func shelfKey(_ key: NotchAskFocus.Key) {
        guard shelfKeyboardEngaged else { return }
        guard islandExpanded, cardModel.page == .shelf, settings.shelfEnabled,
              currentFace == .expanded else { releaseShelfKeyboard(); return }
        if key == .escape { releaseShelfKeyboard(); return }
        ShelfKeyboardInput.handle(key, tray: cardModel.tray)
    }

    func islandKey(code: UInt16, shift: Bool) {
        if shelfKeyboardEngaged { shelfKey(ShelfKeyboardInput.key(code: code, shift: shift)) }
        else { _ = askKey(NotchAskFocus.key(forKeyCode: code, shift: shift)) }
    }
}
