import Foundation
import JRBarCore

/// The daemon's two requests on behalf of a Creator Micro key:
/// `open_window {window}` (the deck's Overview, Usage and Control Center
/// keys) and `reveal_ask` (its ask key). They become the same commands a
/// `jrbar://` link runs, so a key opens exactly what the link would. This
/// is a URL-style open, never synthetic input, and revealing the waiting
/// ask only puts it on the panel: answering stays a click there.
extension AppCommand {
    /// How old a request may be and still run. A key press is answered at
    /// once; a request that reaches the app later (replayed after a
    /// dropped connection) would open a window nobody just asked for.
    nonisolated static let coreRequestMaximumAge: TimeInterval = 10

    /// The command a daemon event asks for, or nil for every other event,
    /// an unknown window, or a request older than `coreRequestMaximumAge`.
    nonisolated static func requested(by event: CoreEvent, now: Date = Date()) -> AppCommand? {
        let command: AppCommand
        switch event.kind {
        case CoreEvent.openWindowKind:
            guard let name = event.window, let window = AppWindow(rawValue: name) else { return nil }
            command = .window(window)
        case CoreEvent.revealAskKind:
            command = .revealAsk
        default:
            return nil
        }
        if let at = event.at, now.timeIntervalSince1970 - at > coreRequestMaximumAge { return nil }
        return command
    }
}
