import AppKit

/// Desktop effects have one default for the app and an inert default for tests.
@MainActor
struct DesktopServices {
    var openURL: @MainActor (URL) -> Bool = { _ in false }
    var reveal: @MainActor ([URL]) -> Void = { _ in }
    var openURLs: @MainActor ([URL], URL, NSWorkspace.OpenConfiguration) -> Void = { _, _, _ in }
    var launch: @MainActor (URL, NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication? = { _, _ in nil }
    var makeStatusItem: @MainActor (CGFloat) -> NSStatusItem = { _ in NSStatusItem() }
    var removeStatusItem: @MainActor (NSStatusItem) -> Void = { _ in }

    static var automatic: Self { WindowPresenter.suppressesDesktop ? Self() : .live }

    private static var live: Self {
        Self(openURL: { url in
            var opened = false
            WindowPresenter.live.perform { opened = NSWorkspace.shared.open(url) }
            return opened
        }, reveal: { urls in
            WindowPresenter.live.perform { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }, openURLs: { urls, application, configuration in
            WindowPresenter.live.perform {
                NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration)
            }
        }, launch: { url, configuration in
            try WindowPresenter.live.validateDesktop()
            return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }, makeStatusItem: { length in
            var item: NSStatusItem?
            WindowPresenter.live.perform { item = NSStatusBar.system.statusItem(withLength: length) }
            return item!
        }, removeStatusItem: { item in
            WindowPresenter.live.perform { NSStatusBar.system.removeStatusItem(item) }
        })
    }

    @discardableResult
    func open(_ url: URL) -> Bool { openURL(url) }

    func open(_ urls: [URL], withApplicationAt application: URL, configuration: NSWorkspace.OpenConfiguration) {
        openURLs(urls, application, configuration)
    }

    @discardableResult
    func openApplication(at url: URL, configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication? {
        try await launch(url, configuration)
    }

    func openApplication(at url: URL, configuration: NSWorkspace.OpenConfiguration,
                         completionHandler: @escaping @MainActor (NSRunningApplication?, Error?) -> Void) {
        Task { @MainActor in
            do { completionHandler(try await launch(url, configuration), nil) }
            catch { completionHandler(nil, error) }
        }
    }
}
