import AppKit
import JRBarCore
import Observation

/// The Control Center's state: the daemon's `state.deck`, the controls lit
/// by `deck_input` events, the sheets, the receipt line, and every deck
/// command. One instance is shared by the window, the rail and the
/// Settings › Devices card.
@MainActor
@Observable
final class DeckStore {
    let core: CoreModel

    /// The daemon's settings document, for provider colour overrides.
    var document: SettingsDocument? { core.settings.map { SettingsDocument($0.document) } }

    /// Controls lit by input check (and by inputs arriving at any time).
    private(set) var flashes = DeckInputFlashes()
    var now = Date().timeIntervalSince1970
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Hovered key in the grid and cell on the rail (different windows).
    var hoveredSlot: Int?
    var railHoveredCell: Int?
    /// The key a session is being dragged over.
    var dropTarget: Int?

    /// The sheets: Apply keymap… (layer picker, auxiliary toggle, the plan
    /// text), Restore original… and Clear absent… (confirmations).
    enum Sheet: Identifiable { case apply, restore, clearAbsent; var id: Self { self } }
    var sheet: Sheet?
    var sheetBusy = false

    /// The Apply sheet's choices and the plan the daemon returned for them.
    var applyLayer: DeckKeymapLayer?
    var applyAuxiliary = false
    var plan: DeckKeymapPlan?
    var planError: String?
    var planLoading = false

    /// The latest receipt: from `state.deck.device.receipt`, or a
    /// `deck_receipt` event (which may arrive before the state).
    private(set) var eventReceipt: DeckReceipt?

    var status: String?
    var lastError: String?

    var isWindowOpen = false
    /// The rail's "…" cell and Settings open the window through this.
    var onOpenControlCenter: (@MainActor () -> Void)?

    /// A state the app expects the daemon to confirm (a pin, a bank step,
    /// a cleared board), shown until the next `state` arrives.
    private var optimistic: (deck: DeckState, generation: Int)?

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var statusClear: DispatchWorkItem?
    @ObservationIgnored private var lastEventID: String?
    @ObservationIgnored private var planRequest: Task<Void, Never>?

    init(core: CoreModel) {
        self.core = core
        trackEvents()
        trackConnection()
    }

    /// A plan request that failed for want of a socket is retried when the
    /// core comes up while the Apply sheet is open.
    private func trackConnection() {
        withObservationTracking {
            _ = core.isLive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.core.isLive, self.sheet == .apply, self.plan == nil { self.loadPlan() }
                self.trackConnection()
            }
        }
    }

    // MARK: Derived

    var isLive: Bool { core.isLive }

    var deck: DeckState? {
        guard let live = core.deck else { return nil }
        if let optimistic, optimistic.generation == (core.state?.generation ?? -1) { return optimistic.deck }
        return live
    }

    var device: DeckDevice? { deck?.device }
    var slots: [DeckSlot] { deck?.keySlots ?? (0..<DeckControls.slotCount).map { DeckSlot(index: $0) } }
    var auxControls: [DeckAuxControl] { deck?.auxControls ?? DeckControls.auxIndices.map { DeckAuxControl(index: $0, label: DeckControls.label(for: $0)) } }
    var banks: DeckBanks { deck?.banks ?? DeckBanks() }
    var railEdge: DeckRailEdge { deck?.rail.edge ?? .off }
    var keymap: DeckKeymap { deck?.keymap ?? DeckKeymap() }
    var inputCheck: Bool { deck?.inputCheck ?? false }
    var lastInput: DeckInput? { deck?.lastInput }
    var settings: DeckSettings { deck?.settings ?? DeckSettings() }

    var hasDevice: Bool { device?.connected == true }
    var needsApproval: Bool { hasDevice && device?.approved == false }
    var hasConflict: Bool { device?.hasConflict == true }
    /// The daemon may write to the pad.
    var canWriteDevice: Bool { device?.isUsable == true }
    /// The rail should be on screen: the core is live and an edge is chosen.
    var railShown: Bool { isLive && railEdge.isShown }

    /// The receipt to show under the device chip: whichever is newer.
    var receipt: DeckReceipt? {
        let fromState = device?.receipt
        guard let eventReceipt else { return fromState }
        guard let fromState else { return eventReceipt }
        return (eventReceipt.at ?? 0) > (fromState.at ?? 0) ? eventReceipt : fromState
    }

    /// "Key 3 pressed 4 s ago", or the Python window's idle line.
    var observedInputText: String {
        guard let input = lastInput else { return "No physical input observed" }
        guard let at = input.at else { return input.sentence }
        let age = max(0, now - at)
        if age < 1 { return "\(input.sentence) just now" }
        if age < 60 { return "\(input.sentence) \(Int(age)) s ago" }
        if age < 3600 { return "\(input.sentence) \(Int(age / 60)) min ago" }
        return "\(input.sentence) \(Int(age / 3600)) h ago"
    }

    /// Sessions the side list offers: every main session the daemon knows,
    /// the ones on this bank first.
    var sessionRows: [CoreSession] {
        let bound = deck?.boundSessions ?? []
        return core.sessions.sorted { a, b in
            let ab = bound.contains(a.id), bb = bound.contains(b.id)
            if ab != bb { return ab }
            return (a.label ?? a.id).localizedCaseInsensitiveCompare(b.label ?? b.id) == .orderedAscending
        }
    }

    func slotIndex(bound session: String) -> Int? { deck?.slot(bound: session)?.index }

    func isLit(_ index: Int) -> Bool { flashes.isLit(index, at: now) }

    /// The key's colour as the app draws it: the daemon's `color` when it is
    /// lit, else the state's lighting colour dimmed for an undriven pad.
    func color(for slot: DeckSlot) -> NSColor {
        if slot.isLit, let hex = slot.color, let color = NSColor(hex: hex) { return color }
        return NSColor(hex: slot.state.lightingHex) ?? .darkGray
    }

    /// Whether the key glows: the daemon lights it, and the pad is driven.
    func glows(_ slot: DeckSlot) -> Bool { slot.isLit }

    // MARK: Lifecycle

    func windowDidOpen() {
        isWindowOpen = true
        startTicker()
    }

    func windowDidClose() {
        isWindowOpen = false
        hoveredSlot = nil
        dropTarget = nil
        sheet = nil
        if !railShown { stopTicker() }
    }

    /// The rail needs the clock too while it is on screen.
    func railDidChange(shown: Bool) {
        if shown { startTicker() } else if !isWindowOpen { stopTicker() }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date().timeIntervalSince1970
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if !self.flashes.isEmpty { self.flashes.expire(at: self.now) }
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func trackEvents() {
        withObservationTracking {
            _ = core.lastEvent
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.consumeEvent()
                self.trackEvents()
            }
        }
    }

    private func consumeEvent() {
        guard let event = core.lastEvent, event.id != lastEventID else { return }
        lastEventID = event.id
        switch event.kind {
        case "deck_input":
            guard let input = event.input else { return }
            now = Date().timeIntervalSince1970
            flashes.record(input, at: now)
            if isWindowOpen || railShown { startTicker() }
        case "deck_receipt":
            if let receipt = event.receipt { eventReceipt = receipt }
        default:
            break
        }
    }

    // MARK: Commands

    /// A click on a key or a rail cell: what the physical press would do.
    func press(index: Int) {
        run("deck_press") { try await self.core.deckPress(index: index) }
    }

    func togglePin(index: Int) {
        guard let deck, let slot = deck.slot(at: index), !slot.isEmpty else { return }
        expect(deck.togglingPin(at: index))
        run("deck_pin", success: slot.pinned ? "Unpinned \(slot.title)" : "Pinned \(slot.title) to key \(index + 1)") {
            try await self.core.deckPin(index: index)
        }
    }

    /// A session dropped on a key: pins the slot that holds it. Slots are
    /// placed by the board, so a drop on another key pins where it sits.
    func drop(session: String, on index: Int) {
        dropTarget = nil
        guard let deck else { return }
        guard let slot = deck.slot(bound: session) else {
            fail("That session is not on this bank")
            return
        }
        if slot.pinned {
            show("\(slot.title) is already pinned to key \(slot.index + 1)")
            return
        }
        expect(deck.togglingPin(at: slot.index))
        run("deck_pin", success: "Pinned \(slot.title) to key \(slot.index + 1)") { try await self.core.deckPin(index: slot.index) }
    }

    func bank(delta: Int) {
        guard banks.hasMultiple else { return }
        if let deck { expect(deck.advancingBank(by: delta)) }
        run("deck_bank") { try await self.core.deckBank(delta: delta) }
    }

    func setRail(edge: DeckRailEdge) {
        if let deck { expect(deck.settingRail(edge: edge)) }
        run("deck_rail") { try await self.core.deckRail(edge: edge) }
    }

    func setInputCheck(_ enabled: Bool) {
        run("deck_check_input", success: enabled ? "Input check: device actions are paused" : "Device actions resume") {
            try await self.core.deckCheckInput(enabled: enabled)
        }
    }

    func approveDevice() {
        run("deck_approve_device", success: "Approved \(device?.serial ?? "the device")") { try await self.core.deckApproveDevice() }
    }

    func setSettings(enabled: Bool? = nil, sessionMode: Bool? = nil, analogEnabled: Bool? = nil) {
        run("deck_set_settings") { try await self.core.deckSetSettings(enabled: enabled, sessionMode: sessionMode, analogEnabled: analogEnabled) }
    }

    // MARK: Sheets

    func openApplySheet() {
        let layers = keymap.layers
        let current = layers.first { $0.profile == (device?.profile ?? 0) && $0.layer == (device?.layer ?? 0) }
        applyLayer = current ?? layers.first ?? DeckKeymapLayer(profile: device?.profile ?? 0, layer: device?.layer ?? 0)
        applyAuxiliary = false
        plan = nil
        planError = nil
        sheet = .apply
        loadPlan()
    }

    func openRestoreSheet() { sheet = .restore }
    func openClearAbsentSheet() { sheet = .clearAbsent }

    func closeSheet() {
        planRequest?.cancel()
        sheet = nil
        sheetBusy = false
    }

    /// `deck_plan_keymap` for the sheet's current choices; 150 ms after the
    /// last change so a quick flip through the layers sends one request.
    func loadPlan() {
        planRequest?.cancel()
        guard let layer = applyLayer else { return }
        let auxiliary = applyAuxiliary
        planLoading = true
        planError = nil
        planRequest = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            do {
                let reply = try await self.core.deckPlanKeymap(profile: layer.profile, layer: layer.layer, includeAuxiliary: auxiliary)
                guard !Task.isCancelled else { return }
                if reply.ok, let plan = DeckKeymapPlan(reply.result) {
                    self.plan = plan
                } else {
                    self.plan = nil
                    self.planError = Self.describe(reply.error)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.plan = nil
                self.planError = Self.describe(error)
            }
            self.planLoading = false
        }
    }

    /// The sheet's confirm button.
    func confirmSheet() {
        guard let sheet else { return }
        sheetBusy = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply: CoreReply
                switch sheet {
                case .apply:
                    let layer = self.applyLayer ?? DeckKeymapLayer(profile: 0, layer: 0)
                    reply = try await self.core.deckApplyKeymap(profile: layer.profile, layer: layer.layer, includeAuxiliary: self.applyAuxiliary)
                case .restore:
                    reply = try await self.core.deckRestoreKeymap()
                case .clearAbsent:
                    if let deck = self.deck { self.expect(deck.clearingAbsent()) }
                    reply = try await self.core.deckClearAbsent()
                }
                if reply.ok {
                    self.sheet = nil
                    switch sheet {
                    case .apply, .restore:
                        if let code = reply.result?["code"]?.stringValue {
                            let receipt = DeckReceipt(code: code, message: reply.result?["message"]?.stringValue, at: Date().timeIntervalSince1970)
                            self.eventReceipt = receipt
                            self.show(receipt.text)
                        } else {
                            self.show(sheet == .restore ? DeckReceiptMessages.message(for: "keymap_restored") : DeckReceiptMessages.message(for: "keymap_verified"))
                        }
                    case .clearAbsent:
                        let removed = reply.result?["removed"]?.intValue ?? 0
                        self.show(removed == 1 ? "Cleared 1 absent slot" : "Cleared \(removed) absent slots")
                    }
                } else {
                    self.fail(Self.describe(reply.error))
                }
            } catch {
                self.fail(Self.describe(error))
            }
            self.sheetBusy = false
        }
    }

    private func expect(_ deck: DeckState) {
        optimistic = (deck, core.state?.generation ?? -1)
    }

    private func run(_ name: String, success: String? = nil, _ body: @escaping @MainActor () async throws -> CoreReply) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await body()
                if reply.ok {
                    if let success { self.show(success) }
                } else {
                    self.optimistic = nil
                    self.fail(Self.describe(reply.error))
                }
            } catch {
                self.optimistic = nil
                self.fail("\(name): \(Self.describe(error))")
            }
        }
    }

    // MARK: Status line

    func show(_ text: String) {
        lastError = nil
        status = text
        scheduleClear()
    }

    func fail(_ text: String) {
        status = nil
        lastError = text
        scheduleClear(after: 6)
    }

    private func scheduleClear(after seconds: Double = 3) {
        statusClear?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.status = nil
                self?.lastError = nil
            }
        }
        statusClear = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    static func describe(_ error: Error?) -> String {
        guard let error else { return "failed" }
        if let reply = error as? CoreReplyError {
            switch reply.code {
            case "device_conflict": return DeckDevice.conflictText + ". " + DeckReceiptMessages.message(for: "device_conflict")
            case "no_device": return reply.message ?? "No Creator Micro 2 is connected."
            case "input_check": return reply.message ?? "Input check is on: device actions are paused."
            default:
                if let message = reply.message, !message.isEmpty { return message }
                return DeckReceiptMessages.message(for: reply.code)
            }
        }
        if let client = error as? CoreClientError { return "\(client)" }
        return error.localizedDescription
    }
}
