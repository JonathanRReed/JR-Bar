import AppKit
import CoreGraphics
import JRBarCore

/// Monitor-setup profiles: the bar takes a layout when a set of displays
/// arrives — the laptop alone, the laptop on the studio display, the lid
/// shut on two externals — the way Bartender 7 follows a monitor setup.
/// The per-display map follows the pointer and rewrites settings on every
/// crossing; a desk is read once, when the screens change. A shut lid
/// takes the built-in display off the set, so clamshell at the desk is
/// its own desk without any extra switch.
enum MenuBarDesk {
    /// One attached display, as a desk knows it.
    struct Display: Equatable, Sendable {
        var builtin: Bool
        var vendor: UInt32
        var model: UInt32
        var serial: UInt32
        var name: String

        /// The display's identity inside a desk key. The built-in panel
        /// is one token whatever its numbers; an external is its vendor,
        /// model and serial — two identical monitors without serials
        /// stay two tokens.
        var token: String {
            builtin ? "builtin" : "\(vendor)-\(model)-\(serial)"
        }
    }

    /// The desk's identity: its displays' tokens, sorted, so the order
    /// macOS lists them in never makes a new desk. Nil for no displays
    /// (a transient mid-reconfiguration read).
    nonisolated static func key(_ displays: [Display]) -> String? {
        guard !displays.isEmpty else { return nil }
        return displays.map(\.token).sorted().joined(separator: "+")
    }

    /// What the card calls the desk: the built-in first, then the
    /// externals by name, and "lid closed" when the laptop is shut on
    /// them.
    nonisolated static func name(_ displays: [Display], lidClosed: Bool) -> String {
        let builtin = displays.filter(\.builtin).map(\.name)
        let externals = displays.filter { !$0.builtin }.map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var name = (builtin + externals).joined(separator: " + ")
        if lidClosed, builtin.isEmpty, !externals.isEmpty { name += " · lid closed" }
        return name.isEmpty ? "No display" : name
    }

    /// The profile a desk's arrival applies: only on a change of desk
    /// (the same desk read again, a relaunch at the same desk, applies
    /// nothing — a profile picked by hand holds), and only for a desk
    /// that has one.
    nonisolated static func profileToApply(previousKey: String?, currentKey: String,
                                           desks: [MenuBarDeskProfile]) -> String? {
        guard previousKey != currentKey else { return nil }
        return desks.first { $0.key == currentKey }?.profileID
    }

    /// The desk list with `key` mapped to `profileID` (empty clears it),
    /// named `name` — the entry keeps its place, a new desk goes last.
    nonisolated static func setting(_ profileID: String, forKey key: String, name: String,
                                    in desks: [MenuBarDeskProfile]) -> [MenuBarDeskProfile] {
        var out = desks
        if profileID.isEmpty {
            out.removeAll { $0.key == key }
        } else if let index = out.firstIndex(where: { $0.key == key }) {
            out[index].profileID = profileID
            out[index].name = name
        } else {
            out.append(MenuBarDeskProfile(key: key, name: name, profileID: profileID))
        }
        return out
    }

    /// The displays attached right now.
    @MainActor
    static func current() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return Display(builtin: CGDisplayIsBuiltin(id) != 0,
                           vendor: CGDisplayVendorNumber(id),
                           model: CGDisplayModelNumber(id),
                           serial: CGDisplaySerialNumber(id),
                           name: screen.localizedName)
        }
    }
}
