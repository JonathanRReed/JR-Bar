import AppKit
import Carbon
import JRBarCore
import SwiftUI

/// What one key press means to a recorder that is listening. Pure, so
/// the grammar — Esc cancels, Delete clears, a chord needs a modifier —
/// is pinned by tests rather than by hand.
enum ShortcutRecorderStep: Equatable, Sendable {
    /// Esc on its own: stop listening, keep the old shortcut.
    case cancel
    /// Delete or Forward Delete on its own: unbind.
    case clear
    /// A chord that may be registered.
    case record(HotkeyChord)
    /// A chord that may not — the recorder keeps listening and says why.
    case invalid(HotkeyChord, HotkeyChord.Problem)
}

enum ShortcutRecorderLogic {
    /// The modifiers a shortcut can carry. Caps Lock, Fn and the
    /// keypad flag ride along on events but are never part of a chord.
    nonisolated static let chordFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    nonisolated static func step(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> ShortcutRecorderStep {
        let mods = flags.intersection(chordFlags)
        if mods.isEmpty {
            switch Int(keyCode) {
            case kVK_Escape: return .cancel
            case kVK_Delete, kVK_ForwardDelete: return .clear
            default: break
            }
        }
        let chord = HotkeyChord(keyCode: UInt32(keyCode),
                                modifiers: MenuBarHotkeyBinding.carbonModifiers(mods))
        if let problem = chord.problem { return .invalid(chord, problem) }
        return .record(chord)
    }

    /// The modifiers held so far, drawn the way the finished chord will
    /// be — "⌃⌥…" while the person is still reaching for the key.
    nonisolated static func heldGlyphs(_ flags: NSEvent.ModifierFlags) -> String {
        let mods = flags.intersection(chordFlags)
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s
    }
}

/// A Raycast-style shortcut field: the current chord as keycaps; a click
/// starts listening, the next chord is the new shortcut. Esc cancels,
/// Delete clears. While it listens every registered JR-Bar shortcut is
/// out of Carbon (`HotkeyCenter.suspend`) — otherwise typing ⌃⌥J to
/// keep it would summon the panel instead of recording.
///
/// A chord another JR-Bar shortcut already holds is not saved silently:
/// the field names the holder and offers to move the key here.
struct ShortcutRecorderField: View {
    /// The registry id this field edits — its own chord never counts as
    /// a conflict.
    let id: String
    let chord: HotkeyChord?
    var center: HotkeyCenter = .shared
    /// The write: a new chord, or nil to unbind.
    let onChange: (HotkeyChord?) -> Void
    /// Moving a chord away from its holder: unbind that id first.
    var onTakeOver: ((String) -> Void)?

    @ViewState private var recording = false
    @ViewState private var held = ""
    @ViewState private var problem: String?
    @ViewState private var takeover: (chord: HotkeyChord, holder: HotkeyCenter.Entry)?
    @ViewState private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    label
                        .frame(minWidth: 96)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(recording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.12),
                                              lineWidth: recording ? 1.5 : 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut")
                .accessibilityValue(chord?.displayString ?? "none")
                .accessibilityHint("Click, then press the keys. Escape cancels, Delete clears.")
                if chord != nil, !recording {
                    Button {
                        onChange(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear this shortcut")
                    .accessibilityLabel("Clear shortcut")
                }
            }
            if let takeover {
                HStack(spacing: 6) {
                    Text("\(takeover.chord.displayString) is “\(takeover.holder.title)”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Use Here") {
                        onTakeOver?(takeover.holder.id)
                        onChange(takeover.chord)
                        self.takeover = nil
                    }
                    .controlSize(.mini)
                    Button("Cancel") { self.takeover = nil }
                        .controlSize(.mini)
                }
            } else if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 240, alignment: .trailing)
            }
        }
        .onDisappear { stopRecording() }
        // A local monitor hears nothing once the app is in the
        // background; leaving it listening would keep every shortcut
        // suspended until the person came back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
    }

    @ViewBuilder
    private var label: some View {
        if recording {
            Text(held.isEmpty ? "Type shortcut…" : held + "…")
                .font(.callout)
                .foregroundStyle(Color.accentColor)
        } else if let chord {
            Text(chord.displayString)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .monospacedDigit()
        } else {
            Text("Record Shortcut")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func toggleRecording() {
        if recording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard !recording else { return }
        recording = true
        held = ""
        problem = nil
        takeover = nil
        center.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        held = ""
        center.resume()
    }

    /// Every key event while listening is ours — none reaches the form
    /// behind the field.
    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            held = ShortcutRecorderLogic.heldGlyphs(event.modifierFlags)
            return nil
        }
        switch ShortcutRecorderLogic.step(keyCode: event.keyCode, flags: event.modifierFlags) {
        case .cancel:
            stopRecording()
        case .clear:
            stopRecording()
            onChange(nil)
        case .invalid(let chord, let why):
            problem = "\(chord.displayString): \(why.sentence)"
        case .record(let chord):
            stopRecording()
            problem = nil
            if chord == self.chord { return nil }
            if let holder = center.owner(of: chord, except: id) {
                takeover = (chord, holder)
            } else {
                onChange(chord)
            }
        }
        return nil
    }
}

/// One shortcut row as Settings › Shortcuts lists it: the action, what
/// the registry says about its key right now, an optional on/off switch
/// and the recorder.
struct ShortcutRow: View {
    let title: String
    var subtitle: String? = nil
    let id: String
    let chord: HotkeyChord?
    /// Present for shortcuts with their own switch (the panel and shelf
    /// keys, the menu-bar keys); an app action is on while it has a key.
    var isOn: Binding<Bool>? = nil
    var center: HotkeyCenter = .shared
    let onChange: (HotkeyChord?) -> Void
    var onTakeOver: ((String) -> Void)?

    /// The registry's word for this id, when it has one worth saying.
    private var statusLine: String? {
        switch center.status(of: id) {
        case .active, .inactive:
            return subtitle
        case .refused(let chord):
            return "\(chord.displayString) is taken by another app."
        case .conflict(let chord, let holder):
            return "\(chord.displayString) is already “\(holder)”."
        }
    }

    private var isProblem: Bool {
        switch center.status(of: id) {
        case .refused, .conflict: return true
        default: return false
        }
    }

    var body: some View {
        LabeledContent {
            HStack(alignment: .top, spacing: 10) {
                ShortcutRecorderField(id: id, chord: chord, center: center,
                                      onChange: onChange, onTakeOver: onTakeOver)
                if let isOn {
                    Toggle("", isOn: isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(chord == nil)
                        .accessibilityLabel("\(title) enabled")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let line = statusLine {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingRowStyle()
    }
}
