import AppKit
import ApplicationServices
import CoreGraphics
import JRBarCore
import Observation
import SwiftUI

/// The Menu Bar utility's extras: the spacers, the underlay, the agents'
/// item and the combined item, with the faces they wear.
extension MenuBarUtility {
    // MARK: Extras — spacers, underlay, agent item, combined item

    /// Bring every settings-driven extra in step: the spacer items,
    /// the underlay, the agent item and the combined system item.
    /// Runs on start and on every settings apply while running.
    func syncExtras() {
        let s = settings()
        MenuBarCombinedItem.log.notice("syncExtras: spacers=\(s.spacers.count) underlay=\(s.barUnderlay) agentItem=\(s.agentStatusItem) combined=\(s.combinedSystemItem)")
        // Under the concealer macOS draws none of our status items, and it
        // orders the bar itself, so a spacer could neither show nor sit
        // between chosen apps: the rows keep their settings and the items
        // stand down until the spacer engine is back (the card says so).
        syncSpacerItems(Self.spacersDrawable(concealing: concealer != nil) ? s.spacers : [])
        if s.barUnderlay {
            underlay.show(appearance: MenuBarCoverAppearance(settings: s))
        } else {
            underlay.hide()
        }
        if s.combinedSystemItem {
            Self.seedPreferredPosition(475,
                                       autosaveName: "com.jonathanreed.jrbar.menubar-combined")
            combinedItem.sync(blank: extrasMirrored)
        } else {
            combinedItem.remove()
        }
        syncAgentItem()
        pushAccessories()
        stepCombinedGate()
    }

    /// Whether spacer items can do their job: only under the spacer
    /// engine. Pure so a test pins the gate.
    nonisolated static func spacersDrawable(concealing: Bool) -> Bool { !concealing }

    /// Whether the mirror carries the extras right now — the real items
    /// then stand blank, so a lift can never flash a second copy.
    var extrasMirrored: Bool { concealer != nil && iconMirrored }

    /// The ids of the compound face's segments.
    nonisolated static let agentAccessoryID = "agents"

    nonisolated static let combinedAccessoryID = "combined"

    /// The extras the mirror wears as segments of its one compound face
    /// while the concealer runs: the agent glance and the combined
    /// readout. Empty under the spacer engine, where the real items draw.
    private func extrasAccessories() -> [MenuBarFaceAccessory] {
        guard concealer != nil, running else { return [] }
        let s = settings()
        var out: [MenuBarFaceAccessory] = []
        if s.agentStatusItem {
            let read = agentState()
            out.append(MenuBarFaceAccessory(
                id: Self.agentAccessoryID,
                image: Self.agentDotImage(tintHex: read.state.tintHex),
                title: read.state.label,
                toolTip: "Agents — \(read.state.label)" + (read.detail.isEmpty ? "" : ": \(read.detail)"),
                accessibilityLabel: "Agents: \(read.state.label)",
                signature: "\(read.state.rawValue)|\(read.detail)"))
        }
        if s.combinedSystemItem {
            let read = combinedItem.readout()
            out.append(MenuBarFaceAccessory(
                id: Self.combinedAccessoryID, image: read.image, title: nil,
                toolTip: "Battery, Wi-Fi, sound and Focus — one item. Click for the panel.",
                accessibilityLabel: read.label, signature: read.signature))
        }
        return out
    }

    /// The mirror's face: the host's, with the extras as segments. A
    /// style that draws no icon lends the mirror no face — only the
    /// segments stand.
    func mirrorFace() -> MenuBarIconFace? {
        guard let host else { return nil }
        var face = host.face
        if !host.anchorWantsVisibleSeat {
            face.image = nil
            face.title = nil
            face.length = 0
        }
        face.accessories = extrasAccessories()
        face.chevronToolTip = Self.chevronToolTip(
            hiddenCount: face.hiddenCount,
            toggleHotkey: resolvedHotkeyBindings().first { $0.action == .toggleReveal && $0.enabled },
            style: settings().revealStyle)
        return face
    }

    /// A binding's key as a menu key equivalent — a letter or a digit;
    /// nil for a key a menu cannot draw as one.
    nonisolated static func menuKeyEquivalent(for binding: MenuBarHotkeyBinding) -> String? {
        let name = MenuBarHotkeys.keyName(for: binding.keyCode)
        guard name.count == 1, let scalar = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) else { return nil }
        return name.lowercased()
    }

    /// The ‹'s tooltip: what a click does, and — when the toggle hotkey
    /// is on — that the same keys open the Item Bar for the keyboard.
    /// Pure so a test pins the copy.
    nonisolated static func chevronToolTip(hiddenCount: Int, toggleHotkey: MenuBarHotkeyBinding?,
                                           style: MenuBarSettings.RevealStyle) -> String? {
        guard hiddenCount > 0 else { return nil }
        let items = "\(hiddenCount) hidden item\(hiddenCount == 1 ? "" : "s")"
        let click = style == .bar ? "click for the Item Bar" : "click to bring them back"
        guard let hotkey = toggleHotkey else { return "\(items) — \(click)" }
        let keys = style == .bar
            ? "\(hotkey.displayString) opens it for the keyboard: arrows, type to filter, Return"
            : "\(hotkey.displayString) does the same"
        return "\(items) — \(click). \(keys)."
    }

    /// Push the current segments to the mirror when they changed.
    private func pushAccessories() {
        guard let mirror = iconMirror, let face = mirrorFace() else { return }
        let wanted = face.accessories.map(\.signature)
        guard wanted != mirror.face.accessories.map(\.signature) else { return }
        mirror.update(face: face)
        updateIconMirror()
    }

    /// A segment's click: the agents open the Overview, the readout its
    /// popover — anchored on the segment.
    func accessoryClicked(_ id: String, view: NSView) {
        switch id {
        case Self.agentAccessoryID: onOpenOverview()
        case Self.combinedAccessoryID: combinedItem.toggle(relativeTo: view)
        default: break
        }
    }

    /// Refresh the extras' faces — the agent glance and the combined
    /// readout change with the world, not with settings. Throttled: the
    /// plan pass calls it every scan.
    func refreshExtrasFaces(force: Bool = false) {
        guard running else { return }
        let now = Date()
        guard force || now.timeIntervalSince(extrasRefreshedAt) >= 2 else { return }
        extrasRefreshedAt = now
        let s = settings()
        if s.combinedSystemItem { combinedItem.sync(blank: extrasMirrored) }
        syncAgentItem()
        pushAccessories()
        stepCombinedGate(now: now)
    }

    func stepCombinedGate(now: Date = Date()) {
        let wanted = running && settings().combinedSystemItem
        guard let hide = combinedGate.step(wanted: wanted, drawn: combinedFaceDrawn, now: now) else { return }
        MenuBarCombinedItem.log.notice("combined item: \(hide ? "face drawn — hiding" : "face not drawn — restoring", privacy: .public) Control Center's items")
        coveredExtrasHidden = hide
        MenuBarCombinedItem.setCoveredExtrasHidden(hide)
    }

    /// Whether the combined face is on screen: under a live assertion
    /// only the mirror's segment can be (macOS draws no item of ours);
    /// with none, the real item once it has a window.
    private var combinedFaceDrawn: Bool {
        guard settings().combinedSystemItem, combinedItem.item != nil else { return false }
        if let concealer, concealer.isConcealing || concealer.isSuspended {
            guard iconMirrored, let mirror = iconMirror, mirror.isVisible else { return false }
            return mirror.face.accessories.contains { $0.id == Self.combinedAccessoryID }
        }
        return combinedItem.item?.button?.window != nil
    }

    /// Everything extras-related off the bar — the disable path and
    /// the deinit share it.
    func removeExtras() {
        for (id, item) in spacerItems {
            item.button?.target = nil
            item.button?.action = nil
            NSStatusBar.system.removeStatusItem(item)
            spacerItems[id] = nil
        }
        underlay.hide()
        combinedItem.remove()
        _ = combinedGate.release()
        if coveredExtrasHidden {
            coveredExtrasHidden = false
            MenuBarCombinedItem.setCoveredExtrasHidden(false)
        }
        if let agentItem {
            agentItem.button?.target = nil
            agentItem.button?.action = nil
            NSStatusBar.system.removeStatusItem(agentItem)
            self.agentItem = nil
        }
        lastAgentSignature = ""
    }

    /// The spacer/label items, in step with `settings().spacers`: born
    /// visible, fixed or hugging length, a click revealing like the
    /// chevron's. Removed rows leave the bar on the spot.
    private func syncSpacerItems(_ spacers: [MenuBarSettings.Spacer]) {
        var live: Set<String> = []
        for spacer in spacers {
            live.insert(spacer.id)
            let autosave = "com.jonathanreed.jrbar.menubar-spacer-\(spacer.id)"
            if spacerItems[spacer.id] == nil {
                Self.seedPreferredPosition(480, autosaveName: autosave)
                let item = NSStatusBar.system.statusItem(
                    withLength: spacer.width > 0 ? spacer.width : NSStatusItem.variableLength)
                item.autosaveName = autosave
                if let button = item.button {
                    button.target = spacerActions
                    button.action = #selector(MenuBarSpacerActions.clicked(_:))
                    button.sendAction(on: [.leftMouseUp])
                    button.toolTip = "JR-Bar spacer — click reveals the hidden items."
                }
                spacerItems[spacer.id] = item
                MenuBarCombinedItem.log.notice("spacer \(spacer.id) created: len=\(item.length) visible=\(item.isVisible) window=\(item.button?.window != nil)")
            }
            guard let item = spacerItems[spacer.id] else { continue }
            if item.button?.title != spacer.label { item.button?.title = spacer.label }
            let wanted = spacer.width > 0 ? spacer.width : NSStatusItem.variableLength
            if item.length != wanted { item.length = wanted }
            if !item.isVisible { item.isVisible = true }
        }
        for (id, item) in spacerItems where !live.contains(id) {
            item.button?.target = nil
            item.button?.action = nil
            NSStatusBar.system.removeStatusItem(item)
            spacerItems[id] = nil
        }
    }

    /// The agent-state item: a tinted dot plus the feed's label —
    /// redrawn only when the signature changes.
    func syncAgentItem() {
        guard settings().agentStatusItem else {
            if let agentItem {
                agentItem.button?.target = nil
                agentItem.button?.action = nil
                NSStatusBar.system.removeStatusItem(agentItem)
                self.agentItem = nil
                lastAgentSignature = ""
            }
            return
        }
        if agentItem == nil {
            Self.seedPreferredPosition(490,
                                       autosaveName: "com.jonathanreed.jrbar.menubar-agents")
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "com.jonathanreed.jrbar.menubar-agents"
            if let button = item.button {
                button.target = agentActions
                button.action = #selector(MenuBarSpacerActions.clicked(_:))
                button.sendAction(on: [.leftMouseUp])
                button.imagePosition = .imageLeft
            }
            agentItem = item
        }
        let read = agentState()
        let blank = extrasMirrored
        let signature = "\(read.state.rawValue)|\(read.detail)" + (blank ? "|blank" : "")
        guard signature != lastAgentSignature else { return }
        lastAgentSignature = signature
        // While the mirror carries the glance the item stands blank —
        // macOS draws nothing of ours under the assertion anyway, and a
        // lift must not flash a second copy.
        agentItem?.button?.image = blank ? nil : Self.agentDotImage(tintHex: read.state.tintHex)
        agentItem?.button?.title = blank ? "" : read.state.label
        agentItem?.button?.toolTip = "Agents — \(read.state.label)"
            + (read.detail.isEmpty ? "" : ": \(read.detail)")
    }

    /// A 10-pt dot in the state's tint — template where the state
    /// carries no colour so the bar keeps its own.
    nonisolated static func agentDotImage(tintHex: String?) -> NSImage? {
        let side: CGFloat = 10
        let colour = tintHex
            .flatMap { MenuBarCoverAppearance.tintComponents($0) }
            .map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
            ?? .labelColor
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            colour.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: side - 1, height: side - 1)).fill()
            return true
        }
        image.isTemplate = tintHex == nil
        return image
    }

    /// The per-display profile follow: the pointer's screen maps to a
    /// profile id; entering a mapped display applies it once two
    /// reconcile passes in a row agree — a pointer straddling a seam
    /// must not write settings on every pass.
    func pollDisplayProfile() {
        let map = settings().displayProfiles
        guard !map.isEmpty else {
            activeDisplayKey = nil
            pendingDisplayKey = nil
            return
        }
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }), let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let key = number.stringValue
        guard key != activeDisplayKey else { return }
        guard let profileID = map[key] else { return }
        let count = pendingDisplayKey?.key == key ? pendingDisplayKey!.count + 1 : 1
        pendingDisplayKey = (key, count)
        guard count >= 2 else { return }
        activeDisplayKey = key
        // Deferred — `applyProfile` writes settings, which reconciles;
        // running it inside `onPlan` would nest a reconcile in one.
        Task { @MainActor [weak self] in self?.applyProfile(id: profileID) }
    }
}
