import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var screenBar: ScreenBarController?
    private var feed: LEDFeed?
    private var monitor: AgentStateMonitor?
    private static let showScreenBarKey = "showScreenBar"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.showScreenBarKey: true])

        let statusItem = StatusItemController()
        let screenBar = ScreenBarController()
        let feed = LEDFeed()
        let monitor = AgentStateMonitor()
        self.statusItem = statusItem
        self.screenBar = screenBar
        self.feed = feed
        self.monitor = monitor

        statusItem.onToggleScreenBar = { shown in
            defaults.set(shown, forKey: Self.showScreenBarKey)
            if shown { screenBar.show() } else { screenBar.hide() }
        }
        feed.onProgram = { [weak statusItem, weak screenBar] text, source in
            screenBar?.apply(programText: text)
            if let rejection = screenBar?.lastRejection {
                statusItem?.setFeed(description: "\(source) (refused: \(rejection))")
            } else {
                statusItem?.setFeed(description: source.description)
            }
        }
        monitor.onChange = { [weak statusItem] state, detail in
            statusItem?.update(state: state, detail: detail)
        }

        let shown = defaults.bool(forKey: Self.showScreenBarKey)
        statusItem.isScreenBarShown = shown
        if shown { screenBar.show() }
        feed.start()
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenBar?.hide()
    }
}
