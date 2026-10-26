import Foundation
import JRBarUI
import Observation

/// The first-run walkthrough's state: which step is on, how each step
/// was left, the permission rows' live facts, and the `setup.json`
/// bookkeeping behind `shouldPresentOnLaunch`.
///
/// Everything the steps touch goes through `model` — injectable, so the
/// store's rules are testable without TCC, EventKit, UserNotifications
/// or a daemon.
@MainActor
@Observable
final class SetupStore {
    /// The five steps, in order.
    enum Step: String, CaseIterable, Identifiable, Sendable {
        case welcome, agents, asks, permissions, appearance, done

        var id: String { rawValue }
        var index: Int { Self.allCases.firstIndex(of: self)! }

        var title: String {
            switch self {
            case .welcome: return "Welcome to JR-Bar"
            case .agents: return "Providers"
            case .asks: return "Only you answer an ask"
            case .permissions: return "Permissions"
            case .appearance: return "Lights"
            case .done: return "You're set"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome: return "Connect the providers on this Mac."
            case .agents: return "Usage requests stay off until you turn them on."
            case .asks: return ""
            case .permissions: return "Each one unlocks a feature; grant what's useful, skip the rest."
            case .appearance: return ""
            case .done: return "What's set, and what's still waiting on you."
            }
        }

        var optional: Bool { self == .permissions || self == .appearance }
        var navigationTitle: String {
            switch self {
            case .welcome: "Welcome"
            case .agents: "Providers"
            case .asks: "Asks"
            case .permissions: "Permissions"
            case .appearance: "Lights"
            case .done: "Ready"
            }
        }

        /// Skip is offered on the three middle steps; Welcome's button is
        /// "Get Started" and Done's is "Finish" — neither can be skipped.
        var skippable: Bool {
            self == .agents || self == .permissions || self == .appearance
        }
    }

    /// One line on the Done step: what a step left in place.
    struct SummaryRow: Equatable, Sendable, Identifiable {
        var id: String { symbol + text }
        var symbol: String
        var text: String
        var detail: String
        /// Green check when the row describes something set; secondary
        /// info mark for what still needs the user.
        var ok: Bool
    }

    /// The world the steps read and act on; `.live(core:)` once the
    /// delegate wires it, the safe defaults before.
    var model: SetupModel { didSet { observeInstalledProviders() } }
    /// "Open Toys" on the Done step — the delegate sends it to the Toys page.
    var onOpenToys: (@MainActor () -> Void)?
    /// Finish/Open Toys have run — the window closes itself on this.
    var onFinished: (@MainActor () -> Void)?
    /// The Done step's "Try it": a made-up ask comes up where real ones
    /// do (`DemoAsk`). Never reaches an agent; tests hand in their own.
    var onTryDemoAsk: @MainActor () -> Void = { DemoAskStore.shared.tryIt() }

    private(set) var step: Step = .welcome
    /// Steps left by the primary button this run.
    private(set) var completedSteps: Set<Step> = []
    /// Steps left by Skip this run.
    private(set) var skippedSteps: Set<Step> = []

    /// The persisted bookkeeping (`setup.json`); `finishedAt` and
    /// `presentedCount` are the launch gate's facts.
    private(set) var state: SetupState
    private(set) var persistenceFailure: String?
    @ObservationIgnored private let persist: (SetupState) throws -> Void

    /// The permission rows' last probe, keyed by row.
    private(set) var statuses: [SetupPermission: SetupPermissionStatus] = [:]
    private(set) var permissionBusy: Set<SetupPermission> = []
    @ObservationIgnored private var permissionReadRevision = 0
    @ObservationIgnored private var permissionReadTask: Task<[SetupPermission: SetupPermissionStatus], Never>?
    @ObservationIgnored private var permissionHealthRevision = 0
    @ObservationIgnored private var usageReadRevision = 0
    /// A hook install in flight per provider — the row's button becomes a spinner.
    private(set) var hookBusy: Set<String> = []
    /// The reply's own words under the row, cleared on a 6 s clock like
    /// the Settings page's notes.
    private(set) var hookNotes: [String: SetupNote] = [:]

    /// The usage questions on the Agents step, one per provider found on
    /// this Mac; `refreshUsageOffers()` fills them from the daemon.
    private(set) var usageOffers: [SetupUsageOffer] = []
    private var usageReadingRevision: Int?
    private(set) var usageOffersFailure: String?
    var loadingUsageOffers: Bool { usageReadingRevision != nil }

    var usageOfferRefreshKey: [String]? {
        guard monitorLive else { return nil }
        return agentRows.filter { $0.detected == true }.map(\.id).sorted()
    }
    /// What the person answered this run. "Not now" is a choice too: it
    /// leaves the provider off and stops the row asking again.
    private(set) var usageChoices: [String: UsageChoice] = [:]
    /// A usage write in flight per provider.
    private(set) var usageBusy: Set<String> = []
    private(set) var usageNotes: [String: SetupNote] = [:]

    enum UsageChoice: Equatable, Sendable {
        case on, notNow
    }

    @ObservationIgnored private var hookNoteClear: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var hookNoteRevision: [String: Int] = [:]
    @ObservationIgnored private let scheduleHookNoteClear:
        (@escaping @MainActor () -> Void) -> DispatchWorkItem
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private let schedulePermissionPoll: (@escaping @MainActor () -> Void) -> Timer
    /// Stopping retires poll ownership without canceling an admitted read.
    @ObservationIgnored private var permissionPollID: UUID?

    /// The Screen Bar's visibility, mirrored locally so the toggle
    /// animates the moment it flips; writes through `model.setScreenBar`.
    /// `present()`'s re-seed must not write the model's own value back to
    /// it, so it runs under `seedingMirrors`.
    var screenBarShown: Bool {
        didSet {
            guard !seedingMirrors, screenBarShown != oldValue else { return }
            model.setScreenBar(screenBarShown)
        }
    }
    /// `menu_bar_icon_style`, mirrored the same way; writes through
    /// `model.setIconStyle` (the Settings store's own path).
    var menuBarIconStyle: String {
        didSet {
            guard !seedingMirrors, menuBarIconStyle != oldValue else { return }
            model.setIconStyle(menuBarIconStyle)
        }
    }

    @ObservationIgnored private var seedingMirrors = false

    init(model: SetupModel = SetupModel(),
         load: () -> SetupState = { SetupStateFile().load() },
         persist: @escaping (SetupState) throws -> Void = { state in
             try SetupStateFile().save(state)
         },
         schedulePermissionPoll: @escaping (@escaping @MainActor () -> Void) -> Timer = { tick in
             let timer = Timer(timeInterval: 1.5, repeats: true) { _ in
                 MainActor.assumeIsolated { tick() }
             }
             timer.tolerance = 0.3
             RunLoop.main.add(timer, forMode: .common)
             return timer
         },
         scheduleHookNoteClear: @escaping
             (@escaping @MainActor () -> Void) -> DispatchWorkItem = { clear in
                 let work = DispatchWorkItem {
                     MainActor.assumeIsolated { clear() }
                 }
                 DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
                 return work
             }) {
        self.model = model
        self.persist = persist
        self.schedulePermissionPoll = schedulePermissionPoll
        self.scheduleHookNoteClear = scheduleHookNoteClear
        self.state = load()
        self.screenBarShown = model.screenBarShown()
        self.menuBarIconStyle = model.iconStyle()
    }

    var onNewProvider: (SetupAgent) -> Void = { _ in }

    @ObservationIgnored private let providerObservation = LifecycleObservation()

    private func observeInstalledProviders() {
        providerObservation.stop()
        providerObservation.start(read: { [weak self] in
            _ = self?.model.monitorLive()
            _ = self?.model.agents()
        }, changed: { [weak self] in
            guard let self, self.model.monitorLive() else { return }
            self.reconcileInstalledProviders(self.model.agents())
        })
    }

    /// First live inventory is a baseline. Later additions get a card, never Setup.
    func reconcileInstalledProviders(_ agents: [SetupAgent]) {
        guard hasFinished, !agents.isEmpty, agents.allSatisfy({ $0.detected != nil }) else { return }
        let installed = agents.filter { $0.detected == true && $0.id != "t3code" }
        let ids = Set(installed.map(\.id))
        let previous = state.knownProviders.map(Set.init)
        let combined = ids.union(previous ?? [])
        guard state.knownProviders == nil || Set(state.knownProviders ?? []) != combined else { return }
        var candidate = state
        candidate.knownProviders = combined.sorted()
        guard commit(candidate) else { return }
        if let previous {
            for agent in installed where !previous.contains(agent.id) { onNewProvider(agent) }
        }
    }

    // MARK: Launch gate

    /// The launch-time gate: present until the walkthrough has run to
    /// Done once, plus at most one more launch if it was dismissed
    /// mid-way. `show()` itself is ungated — "Run setup again" always
    /// opens.
    var shouldPresentOnLaunch: Bool {
        state.finishedAt == nil && state.presentedCount < Self.autoPresentationLimit
    }

    /// How many unfinished launches may auto-present the window before
    /// it stops asking.
    static let autoPresentationLimit = 2

    /// Called by the window on every presentation: re-seeds
    /// the mirrored facts from the live model, and re-reads the
    /// permission rows. A re-run of a finished setup starts over — the
    /// finished stamp stays, so the launch gate never re-arms.
    ///
    /// `launch` is true for the launch gate's own showing: only that counts
    /// toward `autoPresentationLimit` — a hand-opened Setup would
    /// otherwise use up the launches that were meant to offer it.
    /// `restart` is false when the window is already up, so a link or a
    /// notice that opens Setup again never wipes a walkthrough in progress.
    func present(launch: Bool = true, restart: Bool = true) {
        if restart, state.finishedAt != nil {
            step = .welcome
            completedSteps = []
            skippedSteps = []
        }
        var candidate = state
        if launch { candidate.presentedCount += 1 }
        candidate.completedSteps = completedSteps.sorted { $0.index < $1.index }.map(\.rawValue)
        candidate.skippedSteps = skippedSteps.sorted { $0.index < $1.index }.map(\.rawValue)
        commit(candidate)
        seedingMirrors = true
        screenBarShown = model.screenBarShown()
        menuBarIconStyle = model.iconStyle()
        seedingMirrors = false
        Task { await refreshPermissions() }
        Task { await refreshUsageOffers() }
    }

    // MARK: Navigation

    var canGoBack: Bool { step != .welcome }
    var canSkip: Bool { step.skippable }

    /// The primary button's word: Get Started → Next → Finish.
    var nextTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .done: return "Finish"
        default: return "Continue"
        }
    }

    var stepNumber: Int { step.index + 1 }
    var stepCount: Int { Step.allCases.count }

    func goNext() {
        guard step != .done else { finish(); return }
        completedSteps.insert(step)
        skippedSteps.remove(step)
        step = Step.allCases[step.index + 1]
        save()
        if step == .agents { Task { await refreshUsageOffers() } }
        if step == .permissions { Task { await refreshPermissions() } }
    }

    func goBack() {
        guard canGoBack else { return }
        step = Step.allCases[step.index - 1]
        if step == .agents { Task { await refreshUsageOffers() } }
    }

    /// Skip marks the step skipped — last word wins over an earlier
    /// completed mark — and advances like Next.
    func skip() {
        guard step.skippable, step != .done else { return }
        skippedSteps.insert(step)
        completedSteps.remove(step)
        step = Step.allCases[step.index + 1]
        save()
        if step == .permissions { Task { await refreshPermissions() } }
    }

    /// Finish/Open Toys: stamps `finishedAt` (the gate's "never again"),
    /// records the run's outcomes, and lets the window close. The first
    /// finish on a Mac also counts this release's What's New as seen:
    /// everything in it is simply how JR-Bar works for someone new.
    @discardableResult
    func finish() -> Bool {
        var completed = completedSteps
        completed.insert(.done)
        var candidate = state
        candidate.completedSteps = completed.sorted { $0.index < $1.index }.map(\.rawValue)
        candidate.skippedSteps = skippedSteps.sorted { $0.index < $1.index }.map(\.rawValue)
        if candidate.finishedAt == nil, candidate.whatsNewSeen == nil {
            candidate.whatsNewSeen = WhatsNewCatalog.releaseID
        }
        candidate.finishedAt = Date().timeIntervalSince1970
        guard commit(candidate) else { return false }
        completedSteps = completed
        if model.monitorLive() { reconcileInstalledProviders(model.agents()) }
        onFinished?()
        return true
    }

    // MARK: What's New

    /// Whether the walkthrough has ever run to its end — What's New waits
    /// for that.
    var hasFinished: Bool { state.finishedAt != nil }

    /// The release whose What's New was last closed.
    var whatsNewSeen: String? { state.whatsNewSeen }

    /// Closing What's New stamps its release, in the same `setup.json`
    /// this store writes, so neither write loses the other's. Straight
    /// through `persist`: `save()` would rewrite the last run's step
    /// outcomes from this launch's empty ones.
    func markWhatsNewSeen(_ release: String) {
        guard state.whatsNewSeen != release else { return }
        var candidate = state
        candidate.whatsNewSeen = release
        commit(candidate)
    }

    /// The Done step's "Open Toys" — finishes like Finish and opens the
    /// Toys page too.
    func finishToToys() {
        guard finish() else { return }
        onOpenToys?()
    }

    /// The Done step's "Try it": see an ask on the real surfaces, with
    /// Approve and Deny that answer nothing.
    func tryDemoAsk() { onTryDemoAsk() }

    // MARK: Agents step

    var monitorLive: Bool { model.monitorLive() }
    var agentRows: [SetupAgent] { model.agents() }
    var installedAgentRows: [SetupAgent] { agentRows.filter { $0.detected == true && $0.id != "t3code" } }

    /// The Install button's enablement — the Agents page's own rule:
    /// the monitor must be live and the CLI found.
    func canInstall(_ agent: SetupAgent) -> Bool {
        monitorLive && agent.detected != false && !hookBusy.contains(agent.id)
    }

    /// Returns the task so tests can await the row note landing.
    @discardableResult
    func installHooks(for provider: String) -> Task<Void, Never>? {
        guard !hookBusy.contains(provider) else { return nil }
        hookBusy.insert(provider)
        return Task { [weak self] in
            guard let self else { return }
            defer { self.hookBusy.remove(provider) }
            let note = await self.model.installHooks(provider)
            self.noteHook(provider, note)
        }
    }

    /// The same 6 s transient the Settings page's row notes keep.
    private func noteHook(_ provider: String, _ note: SetupNote) {
        hookNotes[provider] = note
        hookNoteClear[provider]?.cancel()
        let revision = (hookNoteRevision[provider] ?? 0) + 1
        hookNoteRevision[provider] = revision
        let work = scheduleHookNoteClear { [weak self] in
            guard let self, self.hookNoteRevision[provider] == revision else { return }
            self.hookNotes[provider] = nil
            self.hookNoteClear[provider] = nil
        }
        hookNoteClear[provider] = work
    }

    // MARK: Usage questions (on the Agents step)

    /// Asks the daemon which providers were found and what each switch says.
    func refreshUsageOffers() async {
        guard !Task.isCancelled else { return }
        usageReadRevision += 1
        let revision = usageReadRevision
        usageReadingRevision = revision
        usageOffersFailure = nil
        defer {
            if usageReadingRevision == revision { usageReadingRevision = nil }
        }
        do {
            let offers = try await model.usageOffers()
            guard revision == usageReadRevision, !Task.isCancelled else { return }
            usageOffers = offers
            for offer in offers where offer.isOn { usageChoices[offer.id] = .on }
        } catch {
            guard revision == usageReadRevision, !Task.isCancelled else { return }
            usageOffersFailure = usageOffers.isEmpty ? "Usage choices could not be loaded."
                : "Usage choices could not be refreshed. Showing the last choices."
        }
    }

    func usageOffer(for provider: String) -> SetupUsageOffer? {
        usageOffers.first { $0.id == provider }
    }

    /// "Turn on": the person read the row's sentence and said yes. Only this
    /// provider changes. Returns the task so tests can await the answer.
    @discardableResult
    func turnOnUsage(for provider: String) -> Task<Void, Never>? {
        setUsage(provider, on: true)
    }

    /// "Turn off" for a provider that was already on.
    @discardableResult
    func turnOffUsage(for provider: String) -> Task<Void, Never>? {
        setUsage(provider, on: false)
    }

    /// "Not now": nothing is asked of the provider and nothing is sent to
    /// the daemon; the row stops asking this run.
    func declineUsage(for provider: String) {
        guard !usageBusy.contains(provider), usageOffer(for: provider)?.isOn != true else { return }
        usageChoices[provider] = .notNow
        usageNotes[provider] = nil
    }

    private func setUsage(_ provider: String, on: Bool) -> Task<Void, Never>? {
        guard monitorLive, !usageBusy.contains(provider) else { return nil }
        usageReadRevision += 1
        usageReadingRevision = nil
        usageBusy.insert(provider)
        return Task { [weak self] in
            guard let self else { return }
            defer {
                self.usageBusy.remove(provider)
                self.usageReadRevision += 1
                self.usageReadingRevision = nil
            }
            let note = await self.model.setUsage(provider, on)
            if note.isError {
                self.usageNotes[provider] = note
                return
            }
            self.usageNotes[provider] = nil
            self.usageChoices[provider] = on ? .on : .notNow
            if let index = self.usageOffers.firstIndex(where: { $0.id == provider }) {
                self.usageOffers[index].isOn = on
            }
        }
    }

    // MARK: Permissions step

    func status(of permission: SetupPermission) -> SetupPermissionStatus {
        statuses[permission] ?? .unknown
    }

    func refreshPermissions() async {
        permissionReadRevision += 1
        let revision = permissionReadRevision
        let read = model.refreshPermissions
        let task = Task { await read() }
        permissionReadTask = task
        let probed = await task.value
        acceptPermissions(probed, revision: revision)
    }

    private func acceptPermissions(_ probed: [SetupPermission: SetupPermissionStatus], revision: Int) {
        guard revision == permissionReadRevision else { return }
        statuses = probed
        permissionReadTask = nil
    }

    private func awaitLatestPermissions(forHealthReview review: Int) async {
        while review == permissionHealthRevision, let task = permissionReadTask {
            let revision = permissionReadRevision
            let probed = await task.value
            guard review == permissionHealthRevision else { return }
            acceptPermissions(probed, revision: revision)
        }
    }

    /// The row's button: `act` runs the request or opens the pane, then
    /// the rows re-read their facts — a grant answers inside the prompt,
    /// a pane takes a moment to reflect a toggle.
    @discardableResult
    func act(on permission: SetupPermission) -> Task<Void, Never> {
        guard !permissionBusy.contains(permission), permission.action(for: status(of: permission)) != nil else {
            return Task {}
        }
        permissionBusy.insert(permission)
        return Task { [weak self] in
            guard let self else { return }
            defer { self.permissionBusy.remove(permission) }
            await self.model.act(permission)
            await self.refreshPermissions()
        }
    }

    /// A live dot while System Settings is open elsewhere: a slow
    /// re-probe, on only while the Permissions step is on screen.
    @discardableResult
    func startPermissionUpdates() -> Task<Void, Never>? {
        guard permissionTimer == nil else { return nil }
        permissionTimer = schedulePermissionPoll { [weak self] in
            _ = self?.pollPermissions()
        }
        return pollPermissions()
    }

    func stopPermissionUpdates() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        permissionPollID = nil
    }

    /// One tick of the live dot: a refresh, unless the last one is still
    /// running (nil then).
    func pollPermissions() -> Task<Void, Never>? {
        guard permissionPollID == nil else { return nil }
        let pollID = UUID()
        permissionPollID = pollID
        return Task { [weak self] in
            guard let self, self.permissionPollID == pollID else { return }
            defer {
                if self.permissionPollID == pollID {
                    self.permissionPollID = nil
                }
            }
            await self.refreshPermissions()
        }
    }

    /// Straight to one step — the lost-permission notice opens on
    /// Permissions. Nothing is marked completed or skipped on the way.
    func jump(to target: Step) {
        step = target
        if target == .permissions { Task { await refreshPermissions() } }
    }

    // MARK: Permission health

    /// One launch-time look: every row probed without prompting, compared
    /// with the grants remembered from the last look, and the new set
    /// remembered. Returns the rows that were granted then and are not
    /// now — empty on the very first look, which only records. Writes
    /// only the remembered grants, never this run's step outcomes.
    func reviewPermissionHealth() async -> [SetupPermission] {
        permissionHealthRevision += 1
        let revision = permissionHealthRevision
        await refreshPermissions()
        guard revision == permissionHealthRevision else { return [] }
        await awaitLatestPermissions(forHealthReview: revision)
        guard revision == permissionHealthRevision else { return [] }
        let review = PermissionHealth.review(remembered: state.grantedPermissions, statuses: statuses)
        if review.remember != state.grantedPermissions {
            var candidate = state
            candidate.grantedPermissions = review.remember
            commit(candidate)
        }
        return review.lost
    }

    // MARK: Appearance step

    var iconPreview: SetupIconPreview { model.iconPreview() }
    var currentIconStyle: StatusIconStyle { StatusIconStyle(setting: menuBarIconStyle) }

    // MARK: Done step

    var activePermissions: [SetupPermission] { model.permissionPlan().active }
    var optionalPermissions: [SetupPermission] { model.permissionPlan().optional }

    /// What's set and what still needs the user, in the order the steps ran.
    var summaryRows: [SummaryRow] {
        var rows: [SummaryRow] = []
        let agents = agentRows
        let hooked = agents.filter { $0.hookStatus == "ok" }
        if skippedSteps.contains(.agents) {
            rows.append(SummaryRow(symbol: "person.2.fill", text: "Agents",
                                   detail: "Skipped. Settings › \(SettingsStore.Page.agents.title) installs hooks any time.", ok: false))
        } else if !monitorLive {
            rows.append(SummaryRow(symbol: "person.2.fill", text: "Agents",
                                   detail: "Monitor offline. Reconnect to check the installed hooks.", ok: false))
        } else if !hooked.isEmpty {
            rows.append(SummaryRow(symbol: "person.2.fill", text: "Agents",
                                   detail: "\(hooked.count) provider\(hooked.count == 1 ? "" : "s") reporting.", ok: true))
        } else if agents.contains(where: { $0.detected == true }) {
            rows.append(SummaryRow(symbol: "person.2.fill", text: "Agents",
                                   detail: "Detected, hooks not installed yet. Settings › \(SettingsStore.Page.agents.title).", ok: false))
        } else {
            rows.append(SummaryRow(symbol: "person.2.fill", text: "Agents",
                                   detail: "No agent CLIs found yet. Install one and it appears in Settings › \(SettingsStore.Page.agents.title).", ok: false))
        }

        if !usageOffers.isEmpty {
            let on = usageOffers.filter(\.isOn).map(\.name)
            if on.isEmpty {
                rows.append(SummaryRow(symbol: "gauge.with.dots.needle.bottom.0percent", text: "Usage",
                                       detail: "Off for every provider. Settings › \(SettingsStore.Page.agents.title) turns each one on.", ok: false))
            } else {
                rows.append(SummaryRow(symbol: "gauge.with.dots.needle.bottom.50percent", text: "Usage",
                                       detail: "On for " + on.joined(separator: ", ") + ". Everything else stays off until you turn it on.",
                                       ok: true))
            }
        }

        let missing = activePermissions.filter { status(of: $0) != .granted }
        if missing.isEmpty {
            rows.append(SummaryRow(symbol: "checkmark.shield.fill", text: "Permissions",
                                   detail: "Permissions for enabled features are ready; other grants are optional.", ok: true))
        } else {
            rows.append(SummaryRow(symbol: "exclamationmark.shield.fill", text: "Permissions",
                                   detail: "Check permissions for: " + missing.map(\.title).joined(separator: ", ") + ".", ok: false))
        }

        rows.append(SummaryRow(symbol: "menubar.rectangle", text: "Menu bar & Screen Bar",
                               detail: "\(currentIconStyle.title) icon · Screen Bar \(screenBarShown ? "on" : "off").",
                               ok: true))
        return rows
    }

    // MARK: Persistence

    private func save() {
        var candidate = state
        candidate.completedSteps = completedSteps.sorted { $0.index < $1.index }.map(\.rawValue)
        candidate.skippedSteps = skippedSteps.sorted { $0.index < $1.index }.map(\.rawValue)
        commit(candidate)
    }

    @discardableResult
    private func commit(_ candidate: SetupState) -> Bool {
        do {
            try persist(candidate)
            state = candidate
            persistenceFailure = nil
            return true
        } catch {
            persistenceFailure = "Setup could not be saved. Try again."
            NSLog("JR-Bar setup: could not save: %@", error.localizedDescription)
            return false
        }
    }
}
