import JRBarCore
import SwiftUI
import UniformTypeIdentifiers

/// The Control Center: the Creator Micro 2 drawn as its real pad, one key
/// per session slot, the dial and joystick around it, the bank pager under
/// it and the session list beside it. Everything on it is the daemon's
/// `state.deck`; the app never talks to the pad itself.
struct ControlCenterView: View {
    @Bindable var store: DeckStore

    static let minSize = CGSize(width: 960, height: 720)

    var body: some View {
        Group {
            if !store.isLive {
                DeckEmptyState(symbol: "bolt.horizontal.circle", title: "Monitor not connected",
                               text: "The Creator Micro 2 is driven by the monitor. The pad appears here as soon as the socket is live.")
            } else {
                content
            }
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { statusPill }
        .sheet(item: $store.sheet) { sheet in
            switch sheet {
            case .apply: ApplyKeymapSheet(store: store)
            case .restore: RestoreKeymapSheet(store: store)
            case .clearAbsent: ClearAbsentSheet(store: store)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: store.status == nil && store.lastError == nil)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if store.hasConflict {
                ConflictBanner(store: store)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: 0) {
                VStack(spacing: 16) {
                    controls
                    DeckDeviceChip(store: store)
                    Spacer(minLength: 0)
                    if store.hasDevice {
                        PadIllustration(store: store)
                    } else {
                        DeckAbsentPad(store: store)
                    }
                    BankPager(store: store)
                    Spacer(minLength: 0)
                    footnote
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                SessionSidebar(store: store)
                    .frame(width: 250)
            }
        }
        .animation(PanelMotion.contents(reduced: store.reduceMotion), value: store.hasConflict)
    }

    /// The Python window's footnote and its observed-input line.
    private var footnote: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: store.inputCheck ? "hand.raised.fill" : "hand.tap")
                    .foregroundStyle(store.inputCheck ? Color.orange : Color.secondary)
                Text(store.observedInputText)
                    .contentTransition(.numericText())
                if store.inputCheck {
                    Text("·").foregroundStyle(.tertiary)
                    Text("Input check: device actions are paused").foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Text("Keys keep their assignments. Explicit mappings override session navigation. No approval or interrupt is emulated.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    /// The Python window's controls: input check, the keymap actions,
    /// Clear absent, and the compact-rail edge popup. Inside the content
    /// rather than the NSToolbar, which shows menus as bare icons.
    private var controls: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { store.inputCheck }, set: { store.setInputCheck($0) })) {
                Label("Check input", systemImage: store.inputCheck ? "hand.tap.fill" : "hand.tap")
            }
            .toggleStyle(.button)
            .tint(store.inputCheck ? .orange : nil)
            .help("While on, physical key, dial and enabled analog sector events are displayed here but never execute actions. Turn it off explicitly to resume; closing this window does not resume them.")
            Button("Apply keymap…") { store.openApplySheet() }
            .disabled(!store.canWriteDevice || store.keymap.needsRecovery)
            .help("Write KV_OAI_AG00…AG12 to one layer of the pad; the first original keymap is backed up and never overwritten")
            Button(store.keymap.needsRecovery ? "Restore original (required)…" : "Restore original…") { store.openRestoreSheet() }
            .tint(store.keymap.needsRecovery ? .orange : nil)
            .disabled(!store.canWriteDevice || store.keymap.state == .stock)
            .help("Put the first private backup of the keymap back on the pad and verify it")
            Button("Clear absent…") { store.openClearAbsentSheet() }
            .disabled(store.deck?.absentSlots.isEmpty ?? true)
            .help("Unpinned sessions no longer observed leave the board; later keys may move")
            Spacer()
            Picker("Compact rail", selection: Binding(get: { store.railEdge }, set: { store.setRail(edge: $0) })) {
                ForEach(DeckRailEdge.allCases, id: \.self) { edge in
                    Text(edge == .off ? "Compact rail: off" : edge.label).tag(edge)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Compact rail display edge: a strip of the thirteen keys on a screen edge, always on top")
            .accessibilityLabel("Compact rail display edge")
        }
        .controlSize(.regular)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(!store.isLive)
    }

    @ViewBuilder
    private var statusPill: some View {
        if let error = store.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
                .padding(.horizontal, 24)
                .transition(.opacity)
        } else if let status = store.status {
            Text(status)
                .font(.callout)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
                .padding(.horizontal, 24)
                .transition(.opacity)
        }
    }
}

// MARK: - Empty states

struct DeckEmptyState: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// No pad: the same silhouette, unlit but still the board (the slots and
/// the rail need no hardware), with the one sentence that helps.
struct DeckAbsentPad: View {
    @Bindable var store: DeckStore

    var body: some View {
        VStack(spacing: 18) {
            PadIllustration(store: store)
                .opacity(0.72)
            VStack(spacing: 4) {
                Text("Turn on your Creator Micro 2 or plug it in").font(.headline)
                Text("It connects over USB or Bluetooth (USB wins when both are up). The first pad seen with a stable serial is offered for approval here. The slots work without it.")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                Text("JR-Bar's hardware pad is the Creator Micro 2. For Stream Deck, see Settings › Remote.")
                    .multilineTextAlignment(.center)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 460)
            }
        }
    }
}

// MARK: - Device chip

struct DeckDeviceChip: View {
    @Bindable var store: DeckStore

    private var device: DeckDevice? { store.device }

    private var statusColor: Color {
        guard let device, device.connected else { return .secondary }
        if device.hasConflict { return .red }
        if !device.approved { return .orange }
        return .green
    }

    private var statusWord: String {
        guard let device, device.connected else {
            // The daemon remembers a serial it has not been told to drive:
            // say so, since Enable (approval) is the step that is missing.
            return device.map { $0.approved ? "Not connected" : "Off, not yet approved" } ?? "Not connected"
        }
        if device.hasConflict { return "Conflict" }
        if !device.approved { return "Needs approval" }
        return "Connected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.grid.3x2.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(device?.displayName ?? "Creator Micro 2").font(.headline)
                        if let transport = device?.transport {
                            Label(transport.label, systemImage: transport == .usb ? "cable.connector" : "wave.3.right")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                                .help("Connected over \(transport.label)")
                        }
                    }
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusWord)
                        if let serial = device?.serial {
                            Text("·").foregroundStyle(.tertiary)
                            Text(serial).font(.system(.caption, design: .monospaced))
                        }
                        if let firmware = device?.firmware {
                            Text("·").foregroundStyle(.tertiary)
                            Text(firmware)
                        }
                        if let profile = device?.profile, let layer = device?.layer {
                            Text("·").foregroundStyle(.tertiary)
                            Text("profile \(profile + 1), layer \(layer + 1)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if store.needsApproval {
                    Button("Approve") { store.approveDevice() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Bind JR-Bar to serial \(device?.serial ?? "?"). Only this pad will ever be driven.")
                } else if device != nil {
                    // A remembered pad that is off still has a keymap on record
                    // (the backup, or the stock state), so the badge stays.
                    KeymapBadge(keymap: store.keymap)
                }
            }
            if let receipt = store.receipt {
                HStack(spacing: 6) {
                    Image(systemName: receipt.isProblem ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(receipt.isProblem ? Color.orange : Color.green)
                    Text(receipt.text)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if let at = receipt.at {
                        Text(Date(timeIntervalSince1970: at), style: .time)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .accessibilityLabel("Receipt: \(receipt.text)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

struct KeymapBadge: View {
    let keymap: DeckKeymap

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: keymap.needsRecovery ? "exclamationmark.triangle.fill" : (keymap.isApplied ? "checkmark.seal.fill" : "keyboard"))
            Text(keymap.label)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(keymap.needsRecovery ? Color.orange : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .help(keymap.isApplied
              ? "One layer of the pad carries KV_OAI_AG00…AG12; the first original keymap is backed up and never overwritten"
              : (keymap.needsRecovery ? "A transfer was interrupted. Backup retained. Choose Restore, not Apply again."
                 : "The pad still types its stock keys"))
    }
}

// MARK: - Conflict banner

struct ConflictBanner: View {
    @Bindable var store: DeckStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(DeckDevice.conflictText).font(.callout.weight(.semibold))
                Text("The firmware has no ownership handshake. Close Work Louder Input and other hardware controllers, then reconnect the pad and inspect again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let detail = store.device?.conflict {
                Text(detail).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - The pad

/// The pad as it is: four key rows of 2, 4, 4 and 3 keys, the dial beside
/// the short top row, the joystick beside the short bottom row.
struct PadIllustration: View {
    @Bindable var store: DeckStore

    static let keySize = CGSize(width: 118, height: 84)
    static let keyGap: CGFloat = 10

    private var rows: [[DeckSlot]] {
        let slots = store.slots
        return DeckControls.rowIndices.map { $0.compactMap { slots[safe: $0] } }
    }

    var body: some View {
        let rows = rows
        let aux = store.auxControls
        VStack(spacing: Self.keyGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { row, slots in
                HStack(spacing: Self.keyGap) {
                    ForEach(slots) { slot in
                        KeyCap(store: store, slot: slot)
                    }
                    if row == 0 {
                        DialControl(store: store, inputs: aux.filter(\.isEncoder))
                            .frame(width: Self.keySize.width * 2 + Self.keyGap, height: Self.keySize.height)
                    } else if row == DeckControls.rows.count - 1 {
                        JoystickControl(store: store, sectors: aux.filter(\.isJoystick))
                            .frame(width: Self.keySize.width, height: Self.keySize.height)
                    }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [Color.primary.opacity(0.07), Color.primary.opacity(0.03)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .fixedSize()
        .opacity(store.needsApproval ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Creator Micro 2 keys")
    }
}

/// One key: the slot's provider tile, label and state word on a dark cap,
/// lit from behind in the daemon's solid colour; a flash when the pad
/// reports a press. A pin badge when pinned; hover shows pin/unpin.
struct KeyCap: View {
    @Bindable var store: DeckStore
    let slot: DeckSlot
    @ViewState private var pressed = false

    private var color: Color { Color(nsColor: store.color(for: slot)) }
    private var lit: Bool { store.isLit(slot.index) }
    private var glow: Bool { store.glows(slot) }
    private var hovered: Bool { store.hoveredSlot == slot.index }
    private var targeted: Bool { store.dropTarget == slot.index }
    private var dim: Bool { slot.isEmpty || slot.isReserved }

    private var glowOpacity: Double {
        if lit { return 1 }
        return glow ? 0.85 : 0
    }

    var body: some View {
        ZStack {
            // The light under the cap.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(lit ? Color.white : color)
                .blur(radius: 16)
                .opacity(glowOpacity * 0.75)
                .padding(-3)
            // The cap.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.10)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(lit ? Color.white.opacity(0.9) : (targeted ? Color.accentColor : color.opacity(glowOpacity * 0.9 + 0.12)),
                              lineWidth: lit || targeted ? 2 : 1)
            content.padding(10)
            if !slot.isEmpty { pinButton }
        }
        .frame(width: PadIllustration.keySize.width, height: PadIllustration.keySize.height)
        .scaleEffect(pressed ? 0.97 : (targeted ? 1.03 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { store.hoveredSlot = $0 ? slot.index : (store.hoveredSlot == slot.index ? nil : store.hoveredSlot) }
        .onTapGesture {
            guard slot.navigable else { return }
            pressed = true
            store.press(index: slot.index)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressed = false }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let session = items.first else { return false }
            store.drop(session: session, on: slot.index)
            return true
        } isTargeted: { over in
            store.dropTarget = over ? slot.index : (store.dropTarget == slot.index ? nil : store.dropTarget)
        }
        .animation(.easeOut(duration: 0.12), value: pressed)
        .animation(.easeOut(duration: 0.15), value: targeted)
        .animation(store.reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.2), value: lit)
        .help("\(slot.title) · \(slot.subtitle)" + (slot.pinned ? " · pinned" : ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(slot.navigable ? .isButton : [])
    }

    private var accessibilityText: String {
        var parts = ["Key \(slot.index + 1)", slot.title, slot.subtitle]
        if slot.pinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                if let provider = slot.provider, !provider.isEmpty {
                    ProviderTile(style: ProviderStyle.style(for: provider, document: store.document), size: 22)
                        .opacity(dim ? 0.5 : 1)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: 22, height: 22)
                }
                Spacer()
                Text("\(slot.index + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .padding(.trailing, (hovered || slot.pinned) && !slot.isEmpty ? 22 : 0)
            }
            Spacer(minLength: 2)
            Text(slot.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(dim ? Color.white.opacity(0.45) : Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 5) {
                if lit {
                    Text("Pressed")
                        .foregroundStyle(.white)
                        .transition(.opacity)
                } else {
                    Circle().fill(color).frame(width: 6, height: 6).opacity(glow ? 1 : 0.35)
                    Text(slot.shortSubtitle)
                        .foregroundStyle(Color.white.opacity(dim ? 0.4 : 0.7))
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
        }
    }

    private var pinButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    store.togglePin(index: slot.index)
                } label: {
                    Image(systemName: slot.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(slot.pinned ? Color.white : Color.white.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(slot.pinned ? 0.18 : 0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(hovered || slot.pinned ? 1 : 0)
                .help(slot.pinned ? "Unpin: the slot may be cleared when its session is absent" : "Pin: keep \(slot.title) on this key through Clear absent")
                .accessibilityLabel(slot.pinned ? "Unpin" : "Pin")
            }
            Spacer()
        }
        .padding(7)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// The encoder: a knob with its three inputs (turn left, turn right,
/// press) named by their explicit mappings. Flashes on `deck_input`.
struct DialControl: View {
    @Bindable var store: DeckStore
    let inputs: [DeckAuxControl]

    private var lit: Bool { inputs.contains { store.isLit($0.index) } }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(lit ? Color.white.opacity(0.9) : Color.white.opacity(0.12), lineWidth: lit ? 2 : 1)
                Capsule()
                    .fill(Color.white.opacity(lit ? 0.9 : 0.35))
                    .frame(width: 3, height: 14)
                    .offset(y: -20)
            }
            .frame(width: 62, height: 62)
            .shadow(color: lit ? .white.opacity(0.5) : .clear, radius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text("Dial").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.85))
                ForEach(inputs) { input in
                    HStack(spacing: 4) {
                        Image(systemName: dialSymbol(input))
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 10)
                        Text(input.mappingLabel ?? "Not configured")
                            .lineLimit(1)
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(store.isLit(input.index) ? Color.white : Color.white.opacity(input.mapping == nil ? 0.35 : 0.65))
                    .help("\(input.label): \(input.mappingLabel ?? "Configure this auxiliary control in Settings > Devices.")")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.14), Color(white: 0.09)], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .animation(.easeOut(duration: 0.2), value: lit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dial: " + inputs.map { "\($0.label) \($0.mappingLabel ?? "not configured")" }.joined(separator: ", "))
    }

    private func dialSymbol(_ input: DeckAuxControl) -> String {
        switch input.index - DeckControls.encoderIndices.lowerBound {
        case 0: return "arrow.counterclockwise"
        case 1: return "arrow.clockwise"
        default: return "circle.fill"
        }
    }
}

/// The joystick: a stick with four sectors (up, right, down, left) that
/// light on `deck_input`, each named by its mapping in the tooltip.
struct JoystickControl: View {
    @Bindable var store: DeckStore
    let sectors: [DeckAuxControl]

    private func sector(_ n: Int) -> DeckAuxControl? { sectors.first { $0.index == DeckControls.joystickIndices.lowerBound + n } }
    private var lit: Bool { sectors.contains { store.isLit($0.index) } }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.14), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            ForEach(0..<4, id: \.self) { n in
                let control = sector(n)
                let on = control.map { store.isLit($0.index) } ?? false
                Image(systemName: ["chevron.up", "chevron.right", "chevron.down", "chevron.left"][n])
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(on ? Color.white : Color.white.opacity(control?.mapping == nil ? 0.2 : 0.5))
                    .offset(x: [0, 30, 0, -30][n], y: [-28, 0, 28, 0][n])
                    .help(control.map { "\($0.label): \($0.mappingLabel ?? "Configure this auxiliary control in Settings > Devices.")" } ?? "")
            }
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.14)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(lit ? Color.white.opacity(0.9) : Color.white.opacity(0.14), lineWidth: lit ? 2 : 1))
                .frame(width: 34, height: 34)
                .shadow(color: lit ? .white.opacity(0.5) : .black.opacity(0.4), radius: lit ? 8 : 3, y: 2)
            Text("Joystick")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(8)
        }
        .animation(.easeOut(duration: 0.2), value: lit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Joystick: " + sectors.map { "\($0.label) \($0.mappingLabel ?? "not configured")" }.joined(separator: ", "))
    }
}

// MARK: - Bank pager

struct BankPager: View {
    @Bindable var store: DeckStore

    var body: some View {
        let banks = store.banks
        HStack(spacing: 14) {
            Button { store.bank(delta: -1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(banks.hasMultiple ? Color.secondary : Color.secondary.opacity(0.3))
            .disabled(!banks.hasMultiple)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Previous bank (wraps)")
            HStack(spacing: 7) {
                ForEach(0..<banks.count, id: \.self) { index in
                    Circle()
                        .fill(index == banks.index ? Color.primary.opacity(0.8) : Color.primary.opacity(0.2))
                        .frame(width: index == banks.index ? 7 : 6, height: index == banks.index ? 7 : 6)
                }
            }
            .animation(.easeOut(duration: 0.15), value: banks.index)
            Button { store.bank(delta: 1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(banks.hasMultiple ? Color.secondary : Color.secondary.opacity(0.3))
            .disabled(!banks.hasMultiple)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Next bank (wraps)")
            Text(banks.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(banks.title)
    }
}

// MARK: - Session sidebar

struct SessionSidebar: View {
    @Bindable var store: DeckStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sessions").font(.headline)
                Spacer()
                Text("\(store.sessionRows.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)
            if store.sessionRows.isEmpty {
                Text("No agents right now.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.sessionRows) { session in
                            SessionDragRow(store: store, session: session)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                Spacer(minLength: 0)
            }
            Divider()
            Label("Drag a session onto its key to pin it there. Pins follow the session, not the key.", systemImage: "hand.draw")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .background(Color.primary.opacity(0.02))
    }
}

struct SessionDragRow: View {
    @Bindable var store: DeckStore
    let session: CoreSession
    @ViewState private var hovered = false

    private var style: ProviderStyle { ProviderStyle.style(for: session.provider, document: store.document) }
    private var activity: SessionActivity { SessionActivity.reduce(session) }
    private var boundKey: Int? { store.slotIndex(bound: session.id) }
    private var pinned: Bool { boundKey.flatMap { store.deck?.slot(at: $0)?.pinned } ?? false }

    var body: some View {
        HStack(spacing: 10) {
            ProviderTile(style: style, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayLabel)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(activity.word)
                    .font(.caption)
                    // Not .secondary: a broken session read exactly like an
                    // idle one here, and a waiting one like both.
                    .foregroundStyle(activity.wordColor)
            }
            Spacer()
            if pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if let key = boundKey {
                Text("\(key + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .help("On key \(key + 1) of this bank")
            } else {
                Text("other bank")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovered ? 1 : 0.35)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovered ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { store.core.openSession(session.id) }
        .draggable(session.id) {
            HStack(spacing: 8) {
                ProviderTile(style: style, size: 20)
                Text(session.displayLabel).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
        }
        .contextMenu {
            if let key = boundKey {
                Button(pinned ? "Unpin key \(key + 1)" : "Pin to key \(key + 1)") { store.togglePin(index: key) }
                Button("Reveal (key \(key + 1))") { store.press(index: key) }
            } else {
                Text("On another bank")
            }
            Button("Open session") { store.core.openSession(session.id) }
        }
        .accessibilityLabel("\(session.displayLabel), \(activity.word)\(boundKey.map { ", key \($0 + 1)" } ?? "")")
    }
}

// MARK: - Sheets

/// Apply keymap…: the Python selection alert (layer picker and the
/// auxiliary switch) and its review alert (the plan text), on one sheet.
struct ApplyKeymapSheet: View {
    @Bindable var store: DeckStore

    private var layers: [DeckKeymapLayer] {
        store.keymap.layers.isEmpty ? [store.applyLayer ?? DeckKeymapLayer(profile: 0, layer: 0)] : store.keymap.layers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose the JR-Bar device layer").font(.title3.weight(.semibold))
                    Text("Close Input and other device controllers before continuing. Only the chosen layer is edited; macro definitions and other layers are preserved. Review the exact changes below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker("Profile and layer to configure", selection: Binding(
                get: { store.applyLayer?.id ?? layers.first?.id ?? "" },
                set: { id in
                    store.applyLayer = layers.first { $0.id == id }
                    store.loadPlan()
                })) {
                ForEach(layers) { layer in
                    Text(layer.label).tag(layer.id)
                }
            }
            .accessibilityLabel("Profile and layer to configure")
            Toggle("Also configure supported dial and joystick mappings", isOn: Binding(
                get: { store.applyAuxiliary },
                set: { store.applyAuxiliary = $0; store.loadPlan() }))
            Divider()
            Text("Review Creator Micro 2 key changes").font(.headline)
            Group {
                if let plan = store.plan {
                    ScrollView {
                        Text(plan.preview)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let error = store.planError {
                    HStack(spacing: 10) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Retry") { store.loadPlan() }
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the pad's keymap…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
            }
            .frame(height: 220)
            HStack {
                if let plan = store.plan {
                    Text(plan.isNoop ? "Nothing to write." : (plan.changes.count == 1 ? "1 change" : "\(plan.changes.count) changes"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { store.closeSheet() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.sheetBusy)
                Button {
                    store.confirmSheet()
                } label: {
                    if store.sheetBusy {
                        ProgressView().controlSize(.small).frame(width: 100)
                    } else {
                        Text("Apply keymap").frame(minWidth: 100)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.sheetBusy || store.plan == nil)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

/// Restore original…: the Python confirmation, word for word.
struct RestoreKeymapSheet: View {
    @Bindable var store: DeckStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(store.keymap.needsRecovery ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Restore the Creator Micro 2 keymap?").font(.title3.weight(.semibold))
                    Text("Close Input and other device controllers first. JR-Bar restores the first private backup only from a recognized applied keymap or a verifiable interrupted JR-Bar transfer. Later unrelated edits are not overwritten.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if store.keymap.needsRecovery {
                Label(DeckReceiptMessages.message(for: "recovery_required"), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if store.keymap.generation != nil {
                Text("The pad reconnected since this transfer — start over; nothing resumes on its own.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button("Cancel") { store.closeSheet() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.sheetBusy)
                Button {
                    store.confirmSheet()
                } label: {
                    if store.sheetBusy {
                        ProgressView().controlSize(.small).frame(width: 110)
                    } else {
                        Text("Restore keymap").frame(minWidth: 110)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.sheetBusy)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}

/// Clear absent…: the Python confirmation, word for word.
struct ClearAbsentSheet: View {
    @Bindable var store: DeckStore

    private var absent: [DeckSlot] { store.deck?.absentSlots ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.grid.3x2.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reassign absent session slots?").font(.title3.weight(.semibold))
                    Text("Unpinned sessions no longer observed will be removed. Later keys may move. Pending session-key actions will be refused.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !absent.isEmpty {
                Text(absent.map { "\($0.index + 1) \($0.title)" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Cancel") { store.closeSheet() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.sheetBusy)
                Button {
                    store.confirmSheet()
                } label: {
                    if store.sheetBusy {
                        ProgressView().controlSize(.small).frame(width: 130)
                    } else {
                        Text("Clear absent slots").frame(minWidth: 130)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.sheetBusy)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}
