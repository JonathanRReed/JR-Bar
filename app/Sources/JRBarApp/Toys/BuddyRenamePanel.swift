import AppKit
import JRBarCore

/// The "Rename…" prompt: a small floating field that appears under the
/// buddy's pill, saves on Return — and on losing key status, the way an
/// inline rename keeps what was typed — and drops the edit on Escape.
/// Borderless and non-activating like the pill; `canBecomeKey` is the
/// override that lets the field take typing without the app coming
/// forward.
@MainActor
final class BuddyRenamePanel: NSPanel {
    private let field: NSTextField
    private var onCommit: ((String) -> Void)?
    private var resignObserver: (any NSObjectProtocol)?

    init() {
        let label = NSTextField(labelWithString: "Name it:")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        let field = NSTextField(frame: .zero)
        field.font = .systemFont(ofSize: 12)
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.field = field

        let hint = NSTextField(labelWithString: "Return saves · Esc cancels · blank keeps the default")
        hint.font = .systemFont(ofSize: 9)
        hint.textColor = .tertiaryLabelColor

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        let stack = NSStackView(views: [row, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 11
        effect.layer?.masksToBounds = true
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = effect
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // One step over the pill's status-bar level so it can sit on it.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

        field.delegate = self
        field.target = self
        field.action = #selector(commitField(_:))

        // Clicked away keeps what was typed — inline-rename rules.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitAndClose() }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Open under `frame` (the pill's), or under the notch area when the
    /// menu could not say where the buddy is. `current` is the stored
    /// name — blank stays blank; the field's placeholder carries the
    /// character's own name.
    func present(near frame: NSRect?, current: String, placeholder: String,
                 commit: @escaping (String) -> Void) {
        field.stringValue = current
        field.placeholderString = placeholder
        onCommit = commit
        let anchor = frame ?? fallbackPillFrame()
        let size = panelSize()
        let anchorPoint = NSPoint(x: anchor.midX, y: anchor.minY)
        let screen = NSScreen.screens.first { $0.frame.contains(anchorPoint) }
            ?? ScreenBarGeometry.preferredScreen() ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
            .insetBy(dx: 6, dy: 6)
        let centre = BuddyPlacement.clampedCenter(
            CGPoint(x: anchor.midX, y: anchor.minY - 8 - size.height / 2),
            size: size, inside: visible)
        setFrame(NSRect(x: (centre.x - size.width / 2).rounded(),
                        y: (centre.y - size.height / 2).rounded(),
                        width: size.width, height: size.height), display: true)
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(field)
        field.selectText(nil)
    }

    /// The pill's spot when the caller had no frame: the top of the
    /// main screen, near where the dock lives.
    private func fallbackPillFrame() -> NSRect {
        NSRect(x: NSScreen.main.map { $0.visibleFrame.midX } ?? 400,
               y: NSScreen.main.map { $0.visibleFrame.maxY - 60 } ?? 700,
               width: 40, height: 30)
    }

    private func panelSize() -> NSSize {
        contentView?.fittingSize ?? NSSize(width: 240, height: 60)
    }

    @objc private func commitField(_ sender: NSTextField) {
        commitAndClose()
    }

    private func commitAndClose() {
        guard let onCommit else { return }
        self.onCommit = nil
        onCommit(field.stringValue)
        orderOut(nil)
    }

    /// Escape drops the edit; every other command is the field's own.
    private func cancelAndClose() {
        onCommit = nil
        orderOut(nil)
    }
}

extension BuddyRenamePanel: NSTextFieldDelegate {
    nonisolated func control(_ control: NSControl, textView: NSTextView,
                             doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            MainActor.assumeIsolated { cancelAndClose() }
            return true
        }
        return false
    }
}
