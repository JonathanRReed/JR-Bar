import AppKit

/// Esc for a card that is held open. Neither card window ever becomes key,
/// so the owner listens for the key itself: a local monitor covers JR-Bar
/// being the active app, a global one every other app.
///
/// A local monitor sees the key of every JR-Bar window, so it must not
/// take them all. Esc pressed in a Settings sheet, a text field or a
/// popover belongs to that window, which is where the person is; swallowing
/// it dismissed the card and left the sheet standing. The watch lets the
/// card go, and consumes the key, only for an Esc that no other JR-Bar
/// window owns: one delivered to the card's own windows, or to no window at
/// all. Any other Esc passes through untouched and the card stays up.
@MainActor
final class CardEscapeWatch {
    static let escapeKeyCode: UInt16 = 53

    /// A key press as the watch reads it: which key, and the window it was
    /// delivered to (nil when no window of ours owns it).
    struct Press {
        let keyCode: UInt16
        let window: AnyObject?
    }

    /// Where key presses come from: AppKit's monitors in the app, a fake
    /// in a test, so no suite listens to the real keyboard.
    struct Source {
        /// Presses delivered to this app. The handler answers whether it
        /// consumed the press; a consumed press goes no further.
        var addLocal: @MainActor (_ handler: @escaping @MainActor (Press) -> Bool) -> Any?
        /// Presses delivered to other apps. A global monitor can only
        /// listen: it never consumes and carries no window.
        var addGlobal: @MainActor (_ handler: @escaping @MainActor (Press) -> Void) -> Any?
        var remove: @MainActor (Any) -> Void

        static let system = Source(
            addLocal: { handler in
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let consumed = MainActor.assumeIsolated {
                        handler(Press(keyCode: event.keyCode, window: event.window))
                    }
                    return consumed ? nil : event
                }
            },
            addGlobal: { handler in
                NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                    MainActor.assumeIsolated {
                        handler(Press(keyCode: event.keyCode, window: nil))
                    }
                }
            },
            remove: { NSEvent.removeMonitor($0) })
    }

    private let source: Source
    private let ownWindows: @MainActor () -> [AnyObject?]
    private let onEscape: @MainActor () -> Void
    private var monitors: [Any] = []

    /// Esc is being listened for.
    var isListening: Bool { !monitors.isEmpty }

    /// `ownWindows` names the card's own windows, read when a press
    /// arrives; `onEscape` lets the card go.
    init(source: Source = .system,
         ownWindows: @escaping @MainActor () -> [AnyObject?],
         onEscape: @escaping @MainActor () -> Void) {
        self.source = source
        self.ownWindows = ownWindows
        self.onEscape = onEscape
    }

    /// Whether an Esc delivered to `window` is the card's to take: the
    /// card's own window, or no window at all. Another JR-Bar window owns
    /// its own Esc.
    nonisolated static func belongsToCard(window: AnyObject?, cardWindows: [AnyObject?]) -> Bool {
        guard let window else { return true }
        return cardWindows.contains { $0 === window }
    }

    /// Listen for Esc. Listening already stands down first, so a repeat
    /// never doubles the monitors.
    func start() {
        stop()
        if let local = source.addLocal({ [weak self] press in self?.handleLocal(press) ?? false }) {
            monitors.append(local)
        }
        if let global = source.addGlobal({ [weak self] press in self?.handleGlobal(press) }) {
            monitors.append(global)
        }
    }

    func stop() {
        for monitor in monitors { source.remove(monitor) }
        monitors = []
    }

    private func handleLocal(_ press: Press) -> Bool {
        guard press.keyCode == Self.escapeKeyCode,
              Self.belongsToCard(window: press.window, cardWindows: ownWindows()) else { return false }
        onEscape()
        return true
    }

    private func handleGlobal(_ press: Press) {
        guard press.keyCode == Self.escapeKeyCode else { return }
        onEscape()
    }
}
