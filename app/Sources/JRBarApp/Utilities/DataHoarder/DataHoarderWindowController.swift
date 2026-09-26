import AppKit
import SwiftUI

/// Keeps the archive's window geometry, not an invisible SwiftUI graph.
/// Closing this window does not stop separately enabled capture or exports.
@MainActor
final class DataHoarderWindowController: NSObject, NSWindowDelegate {
    let model: DataHoarderModel
    private var window: NSWindow?

    init(model: DataHoarderModel) {
        self.model = model
        super.init()
    }

    func show() {
        let target = window ?? makeWindow()
        attachContent(to: target)
        WindowFront.bring(target)
    }

    func makeWindow() -> NSWindow {
        let target = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        target.title = "Data Hoarder"
        target.identifier = NSUserInterfaceItemIdentifier("data-hoarder")
        target.minSize = NSSize(width: 740, height: 480)
        target.isReleasedWhenClosed = false
        target.delegate = self
        target.center()
        target.setFrameAutosaveName("JRBarDataHoarder")
        window = target
        return target
    }

    @discardableResult
    func attachContent(to target: NSWindow) -> NSViewController {
        model.archiveWindowDidOpen()
        return WindowContentLifecycle.attach(to: target, title: "Data Hoarder") {
            WindowContentLifecycle.hosting(DataHoarderView(model: model).task {
                // Enabled maintenance is already owned by DataHoarderView.
                guard !model.enabled else { return }
                await model.refreshStorage()
                guard !Task.isCancelled else { return }
                await model.refreshCaptureStatus()
            })
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let target = notification.object as? NSWindow, target === window else { return }
        WindowContentLifecycle.detach(from: target)
        model.archiveWindowDidClose()
        WindowContentLifecycle.retractWhenLastWindowCloses()
    }
}
