"""Native session workspace and optional compact edge rail; no hardware required.

Native controls provide keyboard/VoiceOver interaction, and state is always
spelled out rather than conveyed by color alone. No provider or USB I/O here.
"""
from __future__ import annotations

import time

import objc
from AppKit import (
    NSAlert,
    NSAlertFirstButtonReturn,
    NSBackingStoreBuffered,
    NSButton,
    NSFloatingWindowLevel,
    NSFont,
    NSPanel,
    NSPopUpButton,
    NSScreen,
    NSSwitchButton,
    NSTextField,
    NSView,
    NSWindow,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskMiniaturizable,
    NSWindowStyleMaskNonactivatingPanel,
    NSWindowStyleMaskTitled,
)
from Foundation import NSObject, NSTimer

from .deck_control_center import change_deck_bank, refresh_deck_board, reveal_deck_session, revoke_deck_context
from .deck_session_board import RAIL_EDGES
from .surface_placement import SurfacePlacement
from .window_presentation import activate_app, present_window

_STATE_NAMES = {
    "input_required": "Needs you", "failure": "Error", "active": "Working",
    "completed": "Completed", "idle": "Idle", "stale": "Stale",
    "unavailable": "Not observed", "unknown": "Unknown", "ended_unconfirmed": "Ended, unconfirmed",
}


class _FlippedDeckView(NSView):
    def isFlipped(self):
        return True


def _label(root, text, frame, *, size=12):
    view = NSTextField.labelWithString_(text)
    view.setFrame_(frame)
    view.setFont_(NSFont.systemFontOfSize_(size))
    root.addSubview_(view)
    return view


def _button(root, title, frame, target, action):
    view = NSButton.alloc().initWithFrame_(frame)
    view.setTitle_(title)
    view.setBezelStyle_(1)
    view.setTarget_(target)
    view.setAction_(action)
    root.addSubview_(view)
    return view


class DeckControlCenterWindow(NSObject):
    def initWithTarget_(self, target):
        self = objc.super(DeckControlCenterWindow, self).init()
        if self is None:
            return None
        self.target = target
        self.timer = None
        self.edge_panel = None
        self.edge_buttons = []
        self.edge = "off"
        self._snapshot = None
        self._build()
        return self

    @objc.python_method
    def _build(self):
        style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            ((0, 0), (750, 618)), style, NSBackingStoreBuffered, False)
        self.window.setTitle_("JR-Bar Control Center")
        self.window.setReleasedWhenClosed_(False)
        self.window.setDelegate_(self)
        root = _FlippedDeckView.alloc().initWithFrame_(((0, 0), (750, 618)))
        self.window.setContentView_(root)
        _label(root, "Sessions & controls", ((20, 18), (460, 30)), size=21)
        self.summary = _label(root, "Loading session slots…", ((20, 52), (710, 24)))
        self.previous = _button(root, "Previous bank", ((20, 86), (130, 30)), self, "previousBank:")
        self.next = _button(root, "Next bank", ((155, 86), (130, 30)), self, "nextBank:")
        self.bank_label = _label(root, "Bank 1", ((300, 91), (145, 24)))
        self.edge_popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(((520, 86), (210, 30)), False)
        for name in ("Compact rail: off", "Left edge", "Right edge", "Top edge", "Bottom edge"):
            self.edge_popup.addItemWithTitle_(name)
        self.edge_popup.setTarget_(self)
        self.edge_popup.setAction_("edgeChanged:")
        self.edge_popup.setAccessibilityLabel_("Compact rail display edge")
        root.addSubview_(self.edge_popup)
        self.buttons = []
        for index in range(20):
            row, column = divmod(index, 4)
            button = _button(root, f"AG{index:02d}", ((20 + column * 179, 130 + row * 65), (173, 59)),
                             self, "slotPressed:")
            button.setTag_(index)
            button.setBezelStyle_(6)
            button.setFont_(NSFont.systemFontOfSize_(11))
            button.cell().setWraps_(True)
            self.buttons.append(button)
        self.input_check = _button(root, "Input check: pause device actions", ((20, 466), (300, 28)),
                                   self, "inputCheckChanged:")
        self.input_check.setButtonType_(NSSwitchButton)
        self.input_check.setAccessibilityHelp_(
            "While checked, physical key, dial and enabled analog sector events are displayed but never execute actions. "
            "Uncheck explicitly to resume configured actions; closing this window does not resume them.")
        self.input_label = _label(root, "No physical input observed", ((325, 469), (400, 24)))
        self.slot_popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(((20, 507), (115, 28)), False)
        for index in range(24):
            self.slot_popup.addItemWithTitle_(f"AG{index:02d}" if index < 20 else f"Analog {index - 19}")
        self.slot_popup.setAccessibilityLabel_("Control to pin or run explicitly")
        root.addSubview_(self.slot_popup)
        _button(root, "Pin / unpin", ((140, 506), (116, 30)), self, "pinSlot:")
        _button(root, "Clear absent slots…", ((266, 506), (165, 30)), self, "clearAbsent:")
        _button(root, "Agent Browser", ((442, 506), (140, 30)), self.target, "openAgentBrowser:")
        _button(root, "Usage Center", ((590, 506), (140, 30)), self.target, "openProviderUsageCenter:")
        self.receipt_label = _label(root, "", ((20, 548), (495, 24)))
        _button(root, "Run selected mapping…", ((530, 545), (200, 30)), self, "runSelectedMapping:")
        _label(root, "Keys keep their assignments. Explicit mappings override session navigation. "
               "No approval or interrupt is emulated.", ((20, 580), (710, 22)), size=10)
        self.window.center()

    @objc.python_method
    def show(self):
        self.refresh_(None)
        if self.timer is None:
            self.timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                0.25, self, "refresh:", None, True)
            self.timer.setTolerance_(0.1)
        present_window(self.window)
        activate_app()

    def refresh_(self, _timer):
        if getattr(self.target, "_runtime_termination_started", False):
            self.shutdown()
            return
        snapshot = refresh_deck_board(self.target)
        self._snapshot = snapshot
        if self.edge != snapshot.rail_edge:
            self.edge = snapshot.rail_edge
            self.edge_popup.selectItemAtIndex_(RAIL_EDGES.index(self.edge))
            if self.edge_panel is not None:
                self.edge_panel.orderOut_(None)
                self.edge_panel = None
            self.edge_buttons = []
        controls = getattr(self.target, "_deck_control_settings", None)
        input_check = bool(getattr(self.target, "_deck_input_check_active", False))
        self.input_check.setState_(int(input_check))
        self.bank_label.setStringValue_(f"Bank {snapshot.bank + 1} of {snapshot.bank_count}")
        output = getattr(self.target, "_creator_micro_output_receipt", None)
        device_state = getattr(output, "reason", "software_only").replace("_", " ")
        self.summary.setStringValue_(f"{device_state.capitalize()} · "
                                    f"{'Session keys' if controls and controls.session_mode else 'Aggregate lighting'} · "
                                    f"{snapshot.unscoped_count} unscoped observations stay in Agent Browser")
        labels = dict(getattr(self.target, "_deck_control_labels", ()))
        last = getattr(self.target, "_deck_last_input", None)
        recent = last is not None and 0 <= time.monotonic() - last[2] <= 0.75
        for index, button in enumerate(self.buttons):
            binding = next((action for key, action in getattr(controls, "bindings", ()) if key == index), None)
            if index < len(snapshot.slots):
                slot = snapshot.slots[index]
                state = _STATE_NAMES.get(slot.state, slot.state)
                title = f"{index + 1}{' · Pinned' if slot.pinned else ''}: {state}\n{slot.title[:22]}"
                detail = f"AG{index:02d}. {slot.title}. {state}. {slot.subtitle}. "
                detail += "Navigation available." if slot.navigable else "No verified navigation target."
            else:
                title = f"AG{index:02d}\n{labels.get(index, 'Auxiliary input')}"
                detail = f"AG{index:02d}. Auxiliary input. Its physical mapping is shown in device setup."
            if binding is not None:
                title = f"AG{index:02d}: Mapped\n{binding.kind.replace('_', ' ')}"
                detail += " Explicit mapping: " + binding.kind.replace("_", " ") + "."
            if recent and last[0] == index:
                title = "INPUT · " + title
            button.setTitle_(title)
            button.setToolTip_(detail)
            button.setAccessibilityLabel_(detail)
        if last is not None:
            index = last[0]
            name = f"AG{index:02d}" if index < 20 else f"Analog sector {index - 19}"
            self.input_label.setStringValue_(f"Observed: {name} · {last[1].replace('_', ' ')}")
        receipt = getattr(self.target, "_deck_action_receipt", None)
        store_error = getattr(getattr(self.target, "_deck_board_store", None), "error", None)
        self.receipt_label.setStringValue_(store_error or (
            f"Last action: {receipt.code.replace('_', ' ')}" if receipt is not None else
            f"Dropped expired/overload inputs: {getattr(self.target, '_deck_dropped_inputs', 0)}"))
        if self.edge != "off":
            self._refresh_edge(snapshot)

    def slotPressed_(self, sender):
        index = int(sender.tag())
        snapshot = self._snapshot
        if snapshot is None or index >= len(snapshot.slots):
            self.receipt_label.setStringValue_("Configure this auxiliary control in Settings > Devices.")
            return
        if getattr(self.target, "_deck_input_check_active", False):
            self.receipt_label.setStringValue_(f"Preview AG{index:02d}; use the physical control to verify its input.")
            return
        settings = getattr(self.target, "_deck_control_settings", None)
        if settings is not None and settings.action_for(index) is not None:
            self.slot_popup.selectItemAtIndex_(index)
            self.receipt_label.setStringValue_("Use Run selected mapping to confirm this mapped action.")
            return
        slot = snapshot.slots[index]
        if slot.identity is not None:
            receipt = reveal_deck_session(self.target, slot.identity, snapshot.revision)
            self.target._deck_action_receipt = receipt
            self.refresh_(None)

    def runSelectedMapping_(self, _sender):
        from .deck_input import ControlInput
        dispatch = getattr(getattr(self.target, "_jrbar_optional_integration_runtime", None), "_deck_dispatch", None)
        settings = getattr(self.target, "_deck_control_settings", None)
        index = int(self.slot_popup.indexOfSelectedItem())
        if dispatch is None or settings is None or not settings.enabled:
            self.receipt_label.setStringValue_("Enable device actions in Settings > Devices first.")
            return
        if getattr(self.target, "_deck_input_check_active", False):
            dispatch.receive_normalized((ControlInput(index, "press"),), virtual=True)
            self.refresh_(None)
            return
        context = dispatch.capture_context()
        alert = NSAlert.alloc().init()
        alert.setMessageText_("Run this saved mapping now?")
        action = settings.action_for(index)
        description = action.kind.replace("_", " ") if action is not None else "Navigate the assigned session"
        if action is not None and action.shortcut_name:
            description += ": " + action.shortcut_name
        alert.setInformativeText_(description + ". This uses the same resolver as the physical device. "
                                  "App shortcuts still require the mapped app to be frontmost.")
        alert.addButtonWithTitle_("Run mapping")
        alert.addButtonWithTitle_("Cancel")
        if alert.runModal() == NSAlertFirstButtonReturn:
            if (settings is not getattr(self.target, "_deck_control_settings", None)
                    or not dispatch.receive_normalized((ControlInput(index, "press"),), virtual=True,
                                                       expected_context=context)):
                self.receipt_label.setStringValue_("The mapping or session bank changed. Review it again before running.")

    def previousBank_(self, _sender):
        change_deck_bank(self.target, -1)

    def nextBank_(self, _sender):
        change_deck_bank(self.target, 1)

    def inputCheckChanged_(self, sender):
        self.target._deck_input_check_active = bool(sender.state())
        runner = getattr(self.target, "_deck_automation_runner", None)
        if self.target._deck_input_check_active and runner is not None:
            self.target._deck_automation_runner = None
            runner.close()
        dispatch = getattr(getattr(self.target, "_jrbar_optional_integration_runtime", None), "_deck_dispatch", None)
        if dispatch is not None:
            dispatch.reset_connection()
        self.refresh_(None)

    def pinSlot_(self, _sender):
        revoke_deck_context(self.target)
        self.target._deck_session_board.toggle_pin(int(self.slot_popup.indexOfSelectedItem()))
        self.target._deck_board_store.submit(self.target._deck_session_board)
        self.refresh_(None)

    def clearAbsent_(self, _sender):
        alert = NSAlert.alloc().init()
        alert.setMessageText_("Reassign absent session slots?")
        alert.setInformativeText_("Unpinned sessions no longer observed will be removed. "
                                  "Later keys may move. Pending session-key actions will be refused.")
        alert.addButtonWithTitle_("Clear absent slots")
        alert.addButtonWithTitle_("Cancel")
        if alert.runModal() == NSAlertFirstButtonReturn:
            revoke_deck_context(self.target)
            self.target._deck_session_board.clear_inactive()
            self.target._deck_board_store.submit(self.target._deck_session_board)
            from .deck_control_center import publish_deck_frame
            publish_deck_frame(self.target)

    def edgeChanged_(self, sender):
        board = self.target._deck_session_board
        board.set_rail_edge(RAIL_EDGES[int(sender.indexOfSelectedItem())])
        self.target._deck_board_store.submit(board)
        self.refresh_(None)

    @objc.python_method
    def _refresh_edge(self, snapshot):
        screen = self.window.screen() or NSScreen.mainScreen()
        if screen is None:
            return
        visible = screen.visibleFrame()
        extent = visible.size.height if self.edge in {"left", "right"} else visible.size.width
        unit = min(30.0, max(18.0, (extent - 20) / 14))
        placement = SurfacePlacement(self.edge, unit * 14, 34)
        try:
            frame = placement.frame(((visible.origin.x, visible.origin.y), (visible.size.width, visible.size.height)))
        except ValueError:
            if self.edge_panel is not None:
                self.edge_panel.orderOut_(None)
            return
        if self.edge_panel is None:
            self.edge_panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
                frame, NSWindowStyleMaskNonactivatingPanel, NSBackingStoreBuffered, False)
            self.edge_panel.setReleasedWhenClosed_(False)
            self.edge_panel.setLevel_(NSFloatingWindowLevel)
            self.edge_panel.setHidesOnDeactivate_(False)
            self.edge_panel.setCollectionBehavior_(NSWindowCollectionBehaviorCanJoinAllSpaces |
                                                   NSWindowCollectionBehaviorFullScreenAuxiliary)
            root = _FlippedDeckView.alloc().initWithFrame_(((0, 0), placement.size))
            self.edge_panel.setContentView_(root)
            for index in range(14):
                button = _button(root, str(index + 1), placement.rect(index * unit, 2, unit, 30),
                                 self, "slotPressed:" if index < 13 else "openWorkspace:")
                button.setTag_(index)
                button.setFont_(NSFont.systemFontOfSize_(10))
                self.edge_buttons.append(button)
        if self.edge_panel.frame() != frame:
            self.edge_panel.setFrame_display_(frame, True)
        for index, button in enumerate(self.edge_buttons):
            button.setFrame_(placement.rect(index * unit, 2, unit, 30))
            if index == 13:
                button.setTitle_("…")
                button.setAccessibilityLabel_(f"Open Control Center, bank {snapshot.bank + 1}")
                continue
            slot = snapshot.slots[index]
            mark = "!" if slot.state in {"input_required", "failure"} else "·" if slot.state == "active" else ""
            button.setTitle_(f"{index + 1}{mark}")
            button.setToolTip_(f"{slot.title}: {_STATE_NAMES.get(slot.state, slot.state)}")
            button.setAccessibilityLabel_(f"Key {index + 1}, {slot.title}, {_STATE_NAMES.get(slot.state, slot.state)}")
            button.setEnabled_(slot.navigable and not getattr(self.target, "_deck_input_check_active", False))
        if not self.edge_panel.isVisible():
            present_window(self.edge_panel, key=False)

    def openWorkspace_(self, _sender):
        self.show()

    def windowWillClose_(self, _notification):
        if self.edge == "off" and self.timer is not None:
            self.timer.invalidate()
            self.timer = None

    @objc.python_method
    def shutdown(self):
        if self.timer is not None:
            self.timer.invalidate()
            self.timer = None
        if self.edge_panel is not None:
            self.edge_panel.orderOut_(None)
        self.window.orderOut_(None)
