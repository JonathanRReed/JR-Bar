import AppKit
import JRBarCore
import SwiftUI

/// The keep-awake duration menu — Atoll's cup presets and Amphetamine's
/// session vocabulary — on every surface that shows the hold: the notch
/// card's Awake chip (right-click or a long press), the panel footer's
/// cup, and the Screen Bar's right ear (right-click). One list, built
/// here, so the three can never offer different things.
///
/// Every choice moves the one hold (`SystemTogglesStore`): the daemon's
/// lease while it is connected, the app's own assertion otherwise.
/// "Until the agents finish" needs the daemon — only it knows when they
/// stop — so it is offered only while the monitor is live.
enum KeepAwakeMenu {
    enum Choice: Hashable, Sendable {
        case seconds(Int)
        /// The next 08:00 at least an hour away — the panel's own
        /// "until tomorrow" rule (`PanelStore.secondsUntilMorning`).
        case untilMorning
        case untilAgentsFinish
        case indefinitely
        /// Toggles whether the display stays on too.
        case keepDisplayOn
        case turnOff
    }

    struct Item: Identifiable, Equatable {
        let choice: Choice
        let title: String
        var checked = false
        var enabled = true
        /// A separator goes above this item.
        var dividerBefore = false

        var id: Choice { choice }
    }

    // MARK: The presets

    /// Where the person's own list of durations lives (seconds).
    nonisolated static let durationsDefaultsKey = "jrbar.keepAwakeDurations"
    /// Atoll's list: 15 m, 30 m, 1 h, 2 h, 4 h.
    nonisolated static let defaultDurations = [900, 1800, 3600, 7200, 14400]
    /// A duration the editor accepts: a minute up to the daemon's 24 h cap.
    nonisolated static let durationRange = 60...86_400
    /// The menu never grows past this many presets.
    nonisolated static let maxDurations = 8

    /// The saved list, cleaned: whole seconds in range, sorted, no
    /// repeats, at most `maxDurations`; nothing usable reads as Atoll's.
    nonisolated static func durations(_ defaults: UserDefaults = .standard) -> [Int] {
        let raw = (defaults.array(forKey: durationsDefaultsKey) ?? []).compactMap { value -> Int? in
            if let number = value as? Int { return number }
            if let number = value as? Double, number.isFinite { return Int(number) }
            return nil
        }
        return normalized(raw)
    }

    nonisolated static func normalized(_ seconds: [Int]) -> [Int] {
        let kept = Array(Set(seconds.filter(durationRange.contains)).sorted().prefix(maxDurations))
        return kept.isEmpty ? defaultDurations : kept
    }

    nonisolated static func setDurations(_ seconds: [Int], _ defaults: UserDefaults = .standard) {
        let kept = normalized(seconds)
        if kept == defaultDurations {
            defaults.removeObject(forKey: durationsDefaultsKey)
        } else {
            defaults.set(kept, forKey: durationsDefaultsKey)
        }
    }

    /// "15 minutes", "1 hour", "1 hour 30 minutes".
    nonisolated static func title(seconds: Int) -> String {
        let minutes = max(1, seconds / 60)
        let hours = minutes / 60
        let rest = minutes % 60
        func unit(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }
        if hours == 0 { return unit(minutes, "minute") }
        if rest == 0 { return unit(hours, "hour") }
        return unit(hours, "hour") + " " + unit(rest, "minute")
    }

    /// The short form for a chip or a preset button: "15 m", "2 h", "1 h 30 m".
    nonisolated static func shortTitle(seconds: Int) -> String {
        let minutes = max(1, seconds / 60)
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(minutes) m" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) m"
    }

    // MARK: The list

    /// The menu, top to bottom: the presets, until the morning, until
    /// the agents finish, indefinitely; then the display switch; then
    /// Turn off while a lease is in force.
    nonisolated static func items(durations: [Int], reading: KeepAwakeReading, displayOn: Bool,
                                  monitorLive: Bool, now: Date) -> [Item] {
        var items = durations.map { Item(choice: .seconds($0), title: "For \(title(seconds: $0))") }
        items.append(Item(choice: .untilMorning, title: PanelStore.morningLabel(verb: "Until", target: morning(from: now))))
        items.append(Item(choice: .untilAgentsFinish, title: "Until the agents finish",
                          checked: reading.state == .lease(.agentsFinish), enabled: monitorLive))
        items.append(Item(choice: .indefinitely, title: "Indefinitely",
                          checked: reading.state == .lease(.indefinite)))
        items.append(Item(choice: .keepDisplayOn, title: "Keep the display on", checked: displayOn,
                          dividerBefore: true))
        items.append(Item(choice: .turnOff, title: "Turn off", enabled: reading.leaseInForce,
                          dividerBefore: true))
        return items
    }

    /// The moment "Until 08:00" ends, on the minute: the rule counts
    /// whole seconds, so `now`'s fraction would otherwise name 07:59.
    nonisolated static func morning(from now: Date) -> Date {
        let end = now.timeIntervalSinceReferenceDate + TimeInterval(PanelStore.secondsUntilMorning(from: now))
        return Date(timeIntervalSinceReferenceDate: (end / 60).rounded() * 60)
    }

    /// What a choice asks of the hold: seconds for a countdown (the
    /// morning one resolved against `now`), nil for indefinitely, 0 to
    /// let go; the agents and display choices are not durations.
    nonisolated static func seconds(for choice: Choice, now: Date) -> Int?? {
        switch choice {
        case .seconds(let seconds): return .some(seconds)
        case .untilMorning: return .some(PanelStore.secondsUntilMorning(from: now))
        case .indefinitely: return .some(nil)
        case .turnOff: return .some(0)
        case .untilAgentsFinish, .keepDisplayOn: return .none
        }
    }

    /// Carry a choice out on the one hold.
    @MainActor
    static func perform(_ choice: Choice, on store: SystemTogglesStore = SystemTogglesStore(),
                        now: Date = Date()) {
        switch choice {
        case .untilAgentsFinish:
            store.holdAwakeUntilAgentsFinish()
        case .keepDisplayOn:
            store.setAwakeKeepsDisplay(!store.awakeKeepsDisplay)
        default:
            if case .some(let hold) = seconds(for: choice, now: now) {
                store.holdAwake(seconds: hold)
            }
        }
    }

    /// The live list for a store right now.
    @MainActor
    static func items(for store: SystemTogglesStore, now: Date = Date()) -> [Item] {
        items(durations: durations(), reading: store.state.awakeReading,
              displayOn: store.awakeKeepsDisplay, monitorLive: store.state.daemonLive, now: now)
    }

    // MARK: AppKit

    /// The same list as an `NSMenu`, for the Screen Bar's ear and a long
    /// press — surfaces that pop a menu at a point rather than host one.
    @MainActor
    static func menu(for store: SystemTogglesStore = SystemTogglesStore(), now: Date = Date()) -> NSMenu {
        let menu = NSMenu(title: "Keep Awake")
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Keep this Mac awake", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for item in items(for: store, now: now) {
            if item.dividerBefore { menu.addItem(.separator()) }
            let entry = NSMenuItem(title: item.title, action: #selector(KeepAwakeMenuTarget.pick(_:)),
                                   keyEquivalent: "")
            entry.target = KeepAwakeMenuTarget.shared
            entry.representedObject = KeepAwakeMenuTarget.Box(choice: item.choice, store: store)
            entry.state = item.checked ? .on : .off
            entry.isEnabled = item.enabled
            menu.addItem(entry)
        }
        return menu
    }

    /// Pop the menu at a screen point — the ear's right-click.
    @MainActor
    static func popUp(at point: NSPoint, store: SystemTogglesStore = SystemTogglesStore()) {
        menu(for: store).popUp(positioning: nil, at: point, in: nil)
    }
}

/// The `NSMenu` items' target: one object for the app's life, carrying
/// each item's choice in its represented object.
@MainActor
final class KeepAwakeMenuTarget: NSObject {
    static let shared = KeepAwakeMenuTarget()

    final class Box: NSObject {
        let choice: KeepAwakeMenu.Choice
        let store: SystemTogglesStore
        init(choice: KeepAwakeMenu.Choice, store: SystemTogglesStore) {
            self.choice = choice
            self.store = store
        }
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? Box else { return }
        KeepAwakeMenu.perform(box.choice, on: box.store)
    }
}

/// The list as SwiftUI menu content — for `.contextMenu` and `Menu`.
struct KeepAwakeMenuItems: View {
    var store = SystemTogglesStore()

    var body: some View {
        let items = KeepAwakeMenu.items(for: store)
        ForEach(items) { item in
            if item.dividerBefore { Divider() }
            if item.checked {
                // A checked row is a toggle, so the menu draws its own
                // checkmark; choosing it again does what it says.
                Toggle(item.title, isOn: Binding(
                    get: { true },
                    set: { _ in KeepAwakeMenu.perform(item.choice, on: store) }))
                    .disabled(!item.enabled)
            } else {
                Button(item.title) { KeepAwakeMenu.perform(item.choice, on: store) }
                    .disabled(!item.enabled)
            }
        }
    }
}
