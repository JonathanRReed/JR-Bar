import AppKit
import ApplicationServices

// MARK: - The Dock's AX tree

/// One application item in Apple's Dock list — frame in AX coordinates.
struct DockAXItem {
    /// The Dock's own tile class: `.app` tiles preview windows,
    /// `.folder` tiles (Downloads, Stacks) pop their directory's
    /// contents, `.minimizedWindow` tiles preview the window parked
    /// in them.
    enum Kind { case app, folder, minimizedWindow }

    /// The tile classes worth previewing — spacers, the separator and
    /// the Trash stay skipped.
    static func kind(forSubrole subrole: String?) -> Kind? {
        switch subrole {
        case "AXApplicationDockItem": return .app
        case "AXFolderDockItem": return .folder
        case "AXMinimizedWindowDockItem": return .minimizedWindow
        default: return nil
        }
    }
    let element: AXUIElement
    let frame: CGRect
    let title: String?
    /// `AXURL` — the file URL the tile points at, when the Dock shares it.
    let url: URL?
    /// `AXStatusLabel` — the tile's badge string ("3", "•"), nil when
    /// the app shows none. ActiveDock's unread dot, verbatim.
    let badge: String?
    let kind: Kind

    init(element: AXUIElement, frame: CGRect, title: String?, url: URL?,
         badge: String? = nil, kind: Kind = .app) {
        self.element = element
        self.frame = frame
        self.title = title
        self.url = url
        self.badge = badge
        self.kind = kind
    }
    /// Stable hover identity: the URL, else the title, else the slot —
    /// two tiles with one title (two copies of an app) still retarget.
    /// Minimized-window tiles carry no URL and can share a title (two
    /// "Untitled" windows), so theirs keeps the slot too.
    var hoverID: String {
        if kind == .minimizedWindow {
            return "window:\(title ?? "")@\(Int(frame.minX)),\(Int(frame.minY))"
        }
        return url?.path ?? title ?? "dock-item@\(Int(frame.minX))"
    }
}

/// The Dock's pid, kept rather than asked for: the preview tick re-reads
/// the Dock's list up to twenty times a second, and each read looked the
/// Dock up among every running app first. The workspace's launch and
/// terminate notices keep the answer; a read that found nothing at it
/// (`forget`) asks the workspace again, so a Dock relaunch no notice
/// reported still heals on the next read.
@MainActor
final class DockPIDCache {
    private var cached: pid_t?
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    /// The workspace query — the tests count it.
    private let lookUp: () -> pid_t?

    /// nil watches the shared workspace's notices.
    init(center: NotificationCenter? = nil,
         lookUp: @escaping () -> pid_t? = {
             NSRunningApplication.runningApplications(withBundleIdentifier: AppleDockReader.dockBundleID)
                 .first?.processIdentifier
         }) {
        let center = center ?? NSWorkspace.shared.notificationCenter
        self.center = center
        self.lookUp = lookUp
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let launched = name == NSWorkspace.didLaunchApplicationNotification
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                let pid = app?.processIdentifier ?? 0
                MainActor.assumeIsolated {
                    self?.noteWorkspace(launched: launched, bundleID: bundleID, pid: pid)
                }
            })
        }
    }

    isolated deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    var pid: pid_t? {
        if let cached { return cached }
        cached = lookUp()
        return cached
    }

    func forget() { cached = nil }

    /// A workspace notice: the Dock's launch brings its new pid, its
    /// exit takes the old one away; any other app's is no news.
    func noteWorkspace(launched: Bool, bundleID: String?, pid: pid_t) {
        guard bundleID == AppleDockReader.dockBundleID else { return }
        cached = launched ? pid : nil
    }
}

/// Read-only queries against the Dock process's accessibility tree,
/// plus the window verbs a preview card offers. Every read fails soft
/// (nil / []) without Accessibility permission — the caller's
/// `AXIsProcessTrusted` gate decides whether that means "no dock" or
/// "no rights".
enum AppleDockReader {
    static let dockBundleID = "com.apple.dock"

    /// The Dock's pid, from `dockProcess` rather than a running-apps
    /// query each time the tick re-reads the list.
    @MainActor
    static func dockPID() -> pid_t? { dockProcess.pid }

    /// A read against the pid failed: ask the workspace again next time.
    @MainActor
    static func forgetDockPID() { dockProcess.forget() }

    @MainActor static let dockProcess = DockPIDCache()

    /// The dock's `AXList` element. Older releases gave it the
    /// `AXDockList` subrole; macOS 26 reports no subrole at all
    /// (verified live), so the role is the key and the subrole only a
    /// tie-break.
    static func dockList(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let children = axChildren(app)
        return children.first { axString($0, kAXSubroleAttribute) == "AXDockList" }
            ?? children.first { axString($0, kAXRoleAttribute) == kAXListRole }
    }

    /// Every previewable tile in the list, in Dock order — app tiles
    /// preview windows, folder tiles (Downloads, Stacks) pop their
    /// directory's contents, minimized-window tiles preview the window
    /// they hold; spacers, the separator and the Trash are skipped.
    /// One walk; the caller keeps the result for a beat and hit-tests
    /// in memory, so the tick never re-walks the whole tree.
    static func items(list: AXUIElement) -> [DockAXItem] {
        axChildren(list).compactMap { child -> DockAXItem? in
            let subrole = axString(child, kAXSubroleAttribute)
            guard let kind = DockAXItem.kind(forSubrole: subrole) else { return nil }
            guard let frame = axFrame(child) else { return nil }
            let badge = axString(child, "AXStatusLabel")
            return DockAXItem(element: child, frame: frame,
                              title: axString(child, kAXTitleAttribute),
                              url: axURL(child),
                              badge: badge?.isEmpty == false ? badge : nil, kind: kind)
        }
    }

    /// The application tile under `point` (AX coordinates), or nil.
    static func item(list: AXUIElement, at point: CGPoint) -> DockAXItem? {
        items(list: list).first { $0.frame.contains(point) }
    }

    static func frame(of element: AXUIElement) -> CGRect? { axFrame(element) }

    /// Repeated AX references are one window; matching titles and frames
    /// are not. Stacked untitled windows must each keep their own card.
    static func uniqueWindowsByIdentity(_ windows: [DockPreviewWindow]) -> [DockPreviewWindow] {
        var seen = Set<AXUIElement>()
        var seenWindowIDs = Set<CGWindowID>()
        return windows.filter { window in
            if let id = window.windowID, !seenWindowIDs.insert(id).inserted { return false }
            guard let element = window.element else { return true }
            return seen.insert(element).inserted
        }
    }

    /// One app's windows as preview rows — AX gives the title, the
    /// frame (the thumbnail match key), the minimized flag, and the
    /// element a later click can raise, close or minimize.
    /// Per-list stamp folded into each row's `id`: plain indices repeat
    /// across fills, and a thumbnail write in flight during a retarget
    /// could then land on the next preview's same-indexed row. Stamped
    /// ids never repeat, so a stale writer finds no row to land on.
    @MainActor private static var rowStamp = 0

    @MainActor
    static func windows(pid: pid_t) -> [DockPreviewWindow] {
        windowsReading(pid: pid).windows
    }

    /// `windows(pid:)` plus whether the app failed to answer inside the
    /// half-second timeout — a hung app, which the switcher then stops
    /// asking for a while instead of paying the wait on every open.
    @MainActor
    static func windowsReading(pid: pid_t) -> (windows: [DockPreviewWindow], unresponsive: Bool) {
        windowsReading(pid: pid, stamp: nextStamp())
    }

    /// A fresh stamp for one app's rows — taken on main for a read that
    /// runs elsewhere (the switcher's side-by-side reads).
    @MainActor
    static func nextStamp() -> Int {
        rowStamp &+= 1
        return rowStamp << 20
    }

    /// The read itself, callable off the main thread (`DockAXWorker`):
    /// `stamp` is folded into each row's id — a caller that never shows
    /// the rows as cards (a ⌘⇥ commit's restore check) passes 0.
    static func windowsReading(pid: pid_t, stamp: Int) -> (windows: [DockPreviewWindow], unresponsive: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let elements = value as? [AXUIElement] else {
            return ([], status == .cannotComplete)
        }
        let windows: [DockPreviewWindow] = elements.enumerated().compactMap { index, element in
            // Sheets, drawers, floating palettes: not windows a person
            // switches to.
            let subrole = axString(element, kAXSubroleAttribute)
            if let subrole, subrole != "AXStandardWindow", subrole != "AXDialog" { return nil }
            let frame = axFrame(element)
            // A row without a real frame can never match a ScreenCaptureKit
            // window — it only renders as an empty card (same floor the
            // thumbnailer applies).
            guard let frame,
                  frame.width >= DockThumbnailer.minimumWindowEdge,
                  frame.height >= DockThumbnailer.minimumWindowEdge else { return nil }
            let title = axString(element, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Untitled window"
            return DockPreviewWindow(
                id: stamp | index,
                title: title,
                minimized: axBool(element, kAXMinimizedAttribute),
                fullScreen: fullScreenState(of: element),
                frame: frame,
                documentURL: documentURL(of: element),
                element: element, windowID: DockWindowIdentity.windowID(of: element))
        }
        return (uniqueWindowsByIdentity(windows), false)
    }

    /// Click a preview card: un-minimize if needed, raise the window,
    /// make it main, and bring the app forward. A card backed by a
    /// minimized-window Dock *tile* (its window never matched an AX
    /// row) answers only `AXPress` — the system's own restore — so the
    /// press goes out too; on a real window the action is unsupported.
    static func raise(_ window: DockPreviewWindow, app: NSRunningApplication?) {
        raiseWindow(window)
        // Plain activate: `.activateAllWindows` brought every window of
        // the app forward and buried the one that was picked.
        app?.activate()
    }

    /// `raise`'s AX half — the writes alone, so a commit can run them on
    /// `DockAXWorker` and activate from main after.
    static func raiseWindow(_ window: DockPreviewWindow) {
        guard let element = window.element else { return }
        if window.minimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                         false as CFTypeRef)
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
        AXUIElementPerformAction(element, "AXRaise" as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, true as CFTypeRef)
    }

    /// The card's ×: press the window's close button. Returns false
    /// when the window offers none.
    @discardableResult
    static func close(_ window: DockPreviewWindow) -> Bool {
        guard let element = window.element else { return false }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &value) == .success,
              let button = value, CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// The card's –: minimize, or bring back a minimized window.
    @discardableResult
    static func setMinimized(_ window: DockPreviewWindow, _ minimized: Bool) -> Bool {
        guard let element = window.element else { return false }
        return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                            minimized as CFTypeRef) == .success
    }

    /// The card's fullscreen verb: the window's own `AXFullScreen`
    /// write — the same attribute the green button toggles. Apps that
    /// never expose it (Finder) report the verb unsupported and the
    /// card hides it.
    @discardableResult
    static func setFullScreen(_ window: DockPreviewWindow, _ on: Bool) -> Bool {
        guard let element = window.element else { return false }
        return AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString,
                                            on as CFTypeRef) == .success
    }

    /// The tile verbs: `AXSize` then `AXPosition` in Quartz space —
    /// size first, since the position write clamps against the
    /// window's current extent and moving first can pin the old size's
    /// origin instead of the tile's.
    @discardableResult
    static func setFrame(_ window: DockPreviewWindow, _ frame: CGRect) -> Bool {
        guard let element = window.element else { return false }
        var origin = frame.origin
        var size = frame.size
        guard let originValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let sized = AXUIElementSetAttributeValue(
            element, kAXSizeAttribute as CFString, sizeValue) == .success
        let moved = AXUIElementSetAttributeValue(
            element, kAXPositionAttribute as CFString, originValue) == .success
        return sized || moved
    }

    /// The window's `AXDocument` — the file it shows, when the app
    /// declares one. Cards carrying a document become drag sources:
    /// dropping the card on another app's Dock tile is macOS's own
    /// "open this in that app" (DockDoor's preview handoff).
    static func documentURL(of element: AXUIElement) -> URL? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXDocumentAttribute as CFString, &value) == .success
        else { return nil }
        if let url = value as? URL { return url.isFileURL ? url : nil }
        if let string = value as? String, !string.isEmpty {
            // Most apps report the document as a POSIX path.
            if string.hasPrefix("/") { return URL(fileURLWithPath: string) }
            return URL(string: string).flatMap { $0.isFileURL ? $0 : nil }
        }
        return nil
    }

    /// Whether `AXFullScreen` is there to write — and its value — read
    /// at list time so the card knows whether to offer the verb.
    /// Returns nil where the attribute is absent or not settable.
    static func fullScreenState(of element: AXUIElement) -> Bool? {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, "AXFullScreen" as CFString, &settable) == .success,
              settable.boolValue else { return nil }
        return axBool(element, "AXFullScreen")
    }

    /// One menu item as the New-window pick reads it.
    struct MenuItemFacts: Equatable {
        var title: String
        var cmdChar: String?
        /// `AXMenuItemCmdModifiers`: 0 is ⌘ alone; bits add ⇧ (1),
        /// ⌥ (2), ⌃ (4), and 8 means no ⌘ at all.
        var cmdModifiers: Int?
        var enabled: Bool
        var hasSubmenu = false
    }

    /// The item "New window" should press: an enabled leaf titled "New
    /// Window", else the enabled leaf the app itself binds to plain ⌘N
    /// (whatever it calls it). nil means the menu offers neither.
    static func newWindowItemIndex(_ items: [MenuItemFacts]) -> Int? {
        let leaves = items.indices.filter { items[$0].enabled && !items[$0].hasSubmenu }
        func normalized(_ title: String) -> String {
            title.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "….")))
                .lowercased()
        }
        if let titled = leaves.first(where: { normalized(items[$0].title) == "new window" }) {
            return titled
        }
        return leaves.first {
            items[$0].cmdChar?.uppercased() == "N" && (items[$0].cmdModifiers ?? 0) == 0
        }
    }

    /// Walk the app's menu bar (past the Apple menu, one submenu deep)
    /// for the New-window item. AX reads only — the press is the caller's.
    static func newWindowMenuItem(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
              let bar = value, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var facts: [MenuItemFacts] = []
        var elements: [AXUIElement] = []
        func collect(_ menu: AXUIElement, depth: Int) {
            for item in axChildren(menu) {
                let submenu = axChildren(item).first
                let modifiers: Int? = {
                    var raw: AnyObject?
                    guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString,
                                                        &raw) == .success else { return nil }
                    return (raw as? NSNumber)?.intValue
                }()
                facts.append(MenuItemFacts(
                    title: axString(item, kAXTitleAttribute) ?? "",
                    cmdChar: axString(item, kAXMenuItemCmdCharAttribute),
                    cmdModifiers: modifiers,
                    enabled: axBool(item, kAXEnabledAttribute),
                    hasSubmenu: submenu != nil))
                elements.append(item)
                if let submenu, depth < 1 { collect(submenu, depth: depth + 1) }
            }
        }
        for top in axChildren(bar as! AXUIElement).dropFirst().prefix(6) {
            for menu in axChildren(top) { collect(menu, depth: 0) }
        }
        return newWindowItemIndex(facts).map { elements[$0] }
    }

    /// The header's "New": the app's own New Window menu item, pressed
    /// through AX — it works where ⌘N means New Document or isn't bound,
    /// and never types into whatever window has focus. Only when the
    /// menu offers neither does the old path run: post ⌘N to the app.
    /// The menu walk is dozens of AX reads against an app that may be
    /// busy — up to half a second each — so it runs on `DockAXWorker`;
    /// the activation it follows stays here.
    static func newWindow(app: NSRunningApplication?) {
        guard let app else { return }
        app.activate()
        let pid = app.processIdentifier
        DockAXWorker.run { pressNewWindow(pid: pid) }
    }

    /// `newWindow`'s AX half: press the menu's New-window item, else
    /// post ⌘N to the app.
    static func pressNewWindow(pid: pid_t) {
        if let item = newWindowMenuItem(pid: pid),
           AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
            return
        }
        // Virtual key 45 is 'n'. Posting to the pid lands the chord in
        // the app's own queue — a real event, and a pid-targeted post
        // asks for no scripting right.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 45, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 45, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }

    // MARK: Primitives

    static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return false }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    static func axURL(_ element: AXUIElement) -> URL? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success
        else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    static func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        // AXValue wraps CGPoint/CGSize; the casts are the documented pattern.
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
