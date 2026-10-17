import AppKit
import Testing
@testable import JRBarApp

@MainActor
@Suite("Item Bar filter control ownership")
struct MenuBarFilterEditorTests {
    private final class Window: NSWindow {
        var requested: NSResponder?
        var current: NSResponder?
        override var firstResponder: NSResponder? { current }
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            requested = responder
            current = responder
            return true
        }
    }

    private final class MarkedEditor: NSTextView {
        override func hasMarkedText() -> Bool { true }
    }

    private func window() -> Window {
        let window = Window(contentRect: NSRect(x: 0, y: 0, width: 160, height: 30),
                            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.requested = nil
        return window
    }

    @Test("text focus targets only the registered control's own window")
    func sameWindowFocusAndClear() {
        let own = window()
        let foreign = window()
        let field = MenuBarFilterField.Field(frame: .zero)
        own.contentView?.addSubview(field)
        let editor = MenuBarFilterEditor()
        editor.attach(field)
        field.delegate = field
        #expect(!editor.focus(in: foreign))
        #expect(foreign.requested == nil)
        #expect(editor.focus(in: own))
        #expect(own.requested === field)
        editor.clear()
        own.requested = nil
        #expect(!editor.focus(in: own))
        #expect(own.requested == nil)
        #expect(field.delegate == nil)
    }

    @Test("a foreign marked editor keeps its composition rather than losing focus")
    func markedEditorRetainsFocus() {
        let own = window()
        let field = MenuBarFilterField.Field(frame: .zero)
        own.contentView?.addSubview(field)
        let editor = MenuBarFilterEditor()
        editor.attach(field)
        let marked = MarkedEditor(frame: .zero)
        own.current = marked
        #expect(!editor.focus(in: own))
        #expect(own.requested == nil)
        #expect(own.current === marked)
        editor.clear()
    }

    @Test("dismantling an old field cannot retire its replacement")
    func oldControlDismantle() {
        let own = window()
        let old = MenuBarFilterField.Field(frame: .zero)
        let replacement = MenuBarFilterField.Field(frame: .zero)
        own.contentView?.addSubview(old)
        own.contentView?.addSubview(replacement)
        let editor = MenuBarFilterEditor()
        editor.attach(old)
        editor.attach(replacement)
        MenuBarFilterField.dismantleNSView(old, coordinator: ())
        #expect(editor.focus(in: own))
        #expect(own.requested === replacement)
        editor.clear()
    }

    @Test("native control changes publish the whole Unicode query")
    func fullQueryPublication() {
        let field = MenuBarFilterField.Field(frame: .zero)
        var queries: [String] = []
        field.onChange = { queries.append($0) }
        field.stringValue = "日本語 café"
        field.controlTextDidChange(Notification(name: .init("synthetic-filter-change"), object: field))
        #expect(queries == ["日本語 café"])
        MenuBarFilterField.dismantleNSView(field, coordinator: ())
    }
}
