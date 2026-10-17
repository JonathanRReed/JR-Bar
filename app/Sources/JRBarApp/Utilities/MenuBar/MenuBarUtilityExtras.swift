import AppKit
import CoreGraphics
import JRBarCore

/// The Menu Bar utility's extras: the underlay and the per-display profile
/// follow. JR-Bar has one status item; nothing here creates another, and
/// nothing here writes a Control Center preference.
extension MenuBarUtility {
    // MARK: Extras — the underlay

    /// Bring every settings-driven extra in step: the underlay. Runs on
    /// start and on every settings apply while running.
    func syncExtras() {
        let s = settings()
        if s.barUnderlay {
            underlay.show(appearance: MenuBarCoverAppearance(settings: s))
        } else {
            underlay.hide()
        }
    }

    /// A binding's key as a menu key equivalent — a letter or a digit;
    /// nil for a key a menu cannot draw as one.
    nonisolated static func menuKeyEquivalent(for binding: MenuBarHotkeyBinding) -> String? {
        let name = MenuBarHotkeys.keyName(for: binding.keyCode)
        guard name.count == 1, let scalar = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) else { return nil }
        return name.lowercased()
    }

    /// Everything extras-related off the bar — the disable path and
    /// the deinit share it.
    func removeExtras() {
        underlay.hide()
    }

    /// The per-display profile follow: the pointer's screen maps to a
    /// profile id; entering a mapped display applies it once two
    /// reconcile passes in a row agree — a pointer straddling a seam
    /// must not write settings on every pass.
    func pollDisplayProfile() {
        let map = settings().displayProfiles
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        })
        let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let profileID = MenuBarProfiles.displayProfile(
            observedKey: number?.stringValue, mappings: map,
            activeKey: &activeDisplayKey, pending: &pendingDisplayKey) else { return }
        // Deferred — `applyProfile` writes settings, which reconciles;
        // running it inside `onPlan` would nest a reconcile in one.
        Task { @MainActor [weak self] in self?.applyProfile(id: profileID) }
    }
}
