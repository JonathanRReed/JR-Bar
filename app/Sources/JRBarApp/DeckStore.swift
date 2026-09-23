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
    /// The scope each hardware layer is written for ("automatic" or a
    /// provider id), keyed by `DeckKeymapLayer.id`.
    var applyScopes: [String: String] = [:]
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

    /// The board's active provider scope ("automatic" or a provider id).
    var scope: String { deck?.scope ?? "automatic" }

    /// The provider ids the board cycles through, in the daemon's order.
    var scopes: [String] { deck?.scopes ?? [] }

    /// Every provider the scope pickers may offer: the daemon's cycle order
    /// first, then any provider live in the session list.
    var providerScopes: [String] {
        var ordered = scopes
        for provider in core.sessions.map(\.provider) where !provider.isEmpty && !ordered.contains(provider) {
            ordered.append(provider)
        }
        return ordered
    }

    /// A scope's display name, also the layer name an Apply writes.
    func scopeName(_ scope: String) -> String {
        scope == "automatic" || scope.isEmpty ? "Automatic" : ProviderStyle.style(for: scope).name
    }
    /// The daemon may write to the pad.
    var canWriteDevice: Bool { device?.isUsable == true }
    /// What an asking key's session is asking, for the rail's pill: the
    /// ask card's summary, one line, bounded; nil for any other key.
    func askDetail(for slot: DeckSlot) -> String? {
        guard slot.state == .inputRequired, let session = slot.session else { return nil }
        let ask = core.asks.first { $0.session == session } ?? core.sessions.first { $0.id == session }?.ask
        return Self.askLine(ask?.summary)
    }

    nonisolated static func askLine(_ summary: String?, limit: Int = 90) -> String? {
        guard let summary else { return nil }
        let line = summary.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count <= limit ? line : String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The rail should be on screen: the core is live and an edge is chosen.
    var railShown: Bool { isLive && railEdge.isShown }

    /// The receipt to show under the device chip: whichever is newer.
    var receipt: DeckReceipt? {
        let fromState = device?.receipt
        guard let eventReceipt else { return fromState }
        guard let fromState else { return eventReceipt }
        return (eventReceipt.at ?? 0) > (fromState.at ?? 0) ? eventReceipt : fromState
    }

    /// "Key 3 pressed 4s ago", or the Python window's idle line. The age
    /// words are `PanelStore.elapsed`'s so the panel and the footnote agree.
    var observedInputText: String {
        guard let input = lastInput else { return "No physical input observed" }
        guard let at = input.at else { return input.sentence }
        if now - at < 1 { return "\(input.sentence) just now" }
        guard let elapsed = PanelStore.elapsed(since: Date(timeIntervalSince1970: at),
                                               now: Date(timeIntervalSince1970: now)) else { return input.sentence }
        return "\(input.sentence) \(elapsed) ago"
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

    /// The scope stepper next to the bank pager: the daemon's `deck_scope`.
    func cycleScope(delta: Int) {
        guard scopes.count > 0 else { return }
        run("deck_scope") { try await self.core.deckScope(delta: delta) }
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

    /// The four calibrated analog sectors (AG20–AG23), while
    /// `analog_enabled` is on. A daemon's `aux` array stops at AG19, so a
    /// sector's mapping comes from the explicit `settings.bindings`; a
    /// binding row — even an unbound one — is the daemon's own word.
    nonisolated static func analogControls(in deck: DeckState?) -> [DeckAuxControl] {
        guard let deck, deck.settings.analogEnabled else { return [] }
        let bindings = deck.settings.bindings ?? []
        var byIndex: [Int: DeckAuxControl] = [:]
        for control in deck.aux where DeckControls.analogIndices.contains(control.index) {
            byIndex[control.index] = control
        }
        return DeckControls.analogIndices.map { index in
            if let binding = bindings.first(where: { $0.index == index }) {
                return DeckAuxControl(index: index, label: DeckControls.label(for: index), mapping: binding.action)
            }
            return byIndex[index] ?? DeckAuxControl(index: index, label: DeckControls.label(for: index))
        }
    }

    /// The analog sectors, or none while `analog_enabled` is off.
    var analogControls: [DeckAuxControl] { Self.analogControls(in: deck) }

    /// The full `bindings` payload for `deck_set_settings`: every
    /// auxiliary control's mapping, and the analog sectors' while they
    /// are enabled — the daemon replaces the whole set, so omitting a
    /// bound index would unbind it.
    nonisolated static func auxBindings(controls: [DeckAuxControl], analog: [DeckAuxControl],
                                        changing index: Int, to action: String?) -> [(index: Int, action: String?)] {
        (controls + analog).map { (index: $0.index, action: $0.index == index ? action : $0.mapping) }
    }

    /// Rebind an auxiliary control: `deck_set_settings` replaces the whole
    /// aux set, so the other controls' current mappings go along — the
    /// analog sectors' too, while `analog_enabled` is on.
    func setAuxBinding(index: Int, action: String?) {
        let bindings = Self.auxBindings(controls: auxControls, analog: analogControls, changing: index, to: action)
        run("deck_set_settings") { try await self.core.deckSetSettings(bindings: bindings) }
    }

    // MARK: Sheets

    /// The hardware layers the Apply sheet writes, on the selected profile.
    var applyTargets: [DeckKeymapLayer] {
        Self.applyTargets(layers: keymap.layers, selected: applyLayer, deviceProfile: device?.profile)
    }

    /// Every keymap layer on the selected profile, or the selected layer
    /// alone on a daemon that reports none.
    nonisolated static func applyTargets(layers: [DeckKeymapLayer], selected: DeckKeymapLayer?,
                                         deviceProfile: Int?) -> [DeckKeymapLayer] {
        let profile = selected?.profile ?? deviceProfile ?? 0
        let rows = layers.filter { $0.profile == profile }
        return rows.isEmpty ? [DeckKeymapLayer(profile: profile, layer: selected?.layer ?? 0)] : rows
    }

    func openApplySheet() {
        let layers = keymap.layers
        let current = layers.first { $0.profile == (device?.profile ?? 0) && $0.layer == (device?.layer ?? 0) }
        applyLayer = current ?? layers.first ?? DeckKeymapLayer(profile: device?.profile ?? 0, layer: device?.layer ?? 0)
        applyScopes = [:]
        for row in layers { applyScopes[row.id] = row.boardScope }
        applyAuxiliary = false
        plan = nil
        planError = nil
        sheet = .apply
        loadPlan()
    }

    /// The scope a layer row is written for in the sheet.
    func applyScope(for row: DeckKeymapLayer) -> String { Self.applyScope(applyScopes, for: row) }

    /// The sheet's choice for a layer row, else the scope its layer map
    /// already assigns it.
    nonisolated static func applyScope(_ scopes: [String: String], for row: DeckKeymapLayer) -> String {
        scopes[row.id] ?? row.boardScope
    }

    func setApplyScope(_ scope: String, for row: DeckKeymapLayer) {
        applyScopes[row.id] = scope
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
                // A scope-aware daemon plans the same layers the Apply
                // button writes; an older one ignores `layers` and answers
                // the single-layer plan it would also apply.
                let targets = self.applyTargets
                let reply: CoreReply
                if self.keymap.layers.contains(where: { $0.scope != nil }), !targets.isEmpty {
                    reply = try await self.core.deckPlanKeymap(
                        profile: targets.first?.profile ?? layer.profile, layer: layer.layer,
                        layers: targets.map { (layer: $0.layer, name: self.scopeName(self.applyScope(for: $0))) },
                        includeAuxiliary: auxiliary)
                } else {
                    reply = try await self.core.deckPlanKeymap(profile: layer.profile, layer: layer.layer, includeAuxiliary: auxiliary)
                }
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
                    // A daemon that reports a scope per layer row also
                    // accepts the `layers` write and the `layer_map`
                    // setting; an older one gets the single-layer call.
                    if self.keymap.layers.contains(where: { $0.scope != nil }) {
                        let targets = self.applyTargets
                        reply = try await self.core.deckApplyKeymap(
                            profile: targets.first?.profile ?? 0,
                            layers: targets.map { (layer: $0.layer, name: self.scopeName(self.applyScope(for: $0))) },
                            includeAuxiliary: self.applyAuxiliary)
                        if reply.ok {
                            _ = try? await self.core.deckSetSettings(
                                layerMap: targets.map { (layer: $0.layer, scope: self.applyScope(for: $0)) })
                        }
                    } else {
                        let layer = self.applyLayer ?? DeckKeymapLayer(profile: 0, layer: 0)
                        reply = try await self.core.deckApplyKeymap(profile: layer.profile, layer: layer.layer, includeAuxiliary: self.applyAuxiliary)
                    }
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
