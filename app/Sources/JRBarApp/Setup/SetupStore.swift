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
        case welcome, agents, permissions, appearance, done

        var id: String { rawValue }
        var index: Int { Self.allCases.firstIndex(of: self)! }

        var title: String {
            switch self {
            case .welcome: return "Welcome to JR-Bar"
            case .agents: return "Connect your agents"
            case .permissions: return "Permissions"
            case .appearance: return "Menu bar & Screen Bar"
            case .done: return "You're set"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome: return "A one-minute tour of the two things to switch on."
            case .agents: return "Hooks let each agent report its sessions to the monitor."
            case .permissions: return "Each one unlocks a feature; grant what's useful, skip the rest."
            case .appearance: return "What the menu bar shows, and whether the band is up."
            case .done: return "What's set, and what's still waiting on you."
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
    var model: SetupModel
    /// "Open Toys" on the Done step — the delegate sends it to the Toys page.
    var onOpenToys: (@MainActor () -> Void)?
    /// Finish/Open Toys have run — the window closes itself on this.
    var onFinished: (@MainActor () -> Void)?

    private(set) var step: Step = .welcome
    /// Steps left by the primary button this run.
    private(set) var completedSteps: Set<Step> = []
    /// Steps left by Skip this run.
    private(set) var skippedSteps: Set<Step> = []

    /// The persisted bookkeeping (`setup.json`); `finishedAt` and
    /// `presentedCount` are the launch gate's facts.
    private(set) var state: SetupState
    @ObservationIgnored private let persist: (SetupState) -> Void

    /// The permission rows' last probe, keyed by row.
    private(set) var statuses: [SetupPermission: SetupPermissionStatus] = [:]
    /// A hook install in flight per provider — the row's button becomes a spinner.
    private(set) var hookBusy: Set<String> = []
    /// The reply's own words under the row, cleared on a 6 s clock like
    /// the Settings page's notes.
    private(set) var hookNotes: [String: SetupNote] = [:]

    @ObservationIgnored private var hookNoteClear: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var permissionTimer: Timer?

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
         persist: @escaping (SetupState) -> Void = { state in
             let file = SetupStateFile()
             do { try file.save(state) } catch {
                 NSLog("JR-Bar setup: could not write %@: %@", file.url.path, error.localizedDescription)
             }
         }) {
        self.model = model
        self.persist = persist
        self.state = load()
        self.screenBarShown = model.screenBarShown()
        self.menuBarIconStyle = model.iconStyle()
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

    /// Called by the window on every presentation: counts it, re-seeds
    /// the mirrored facts from the live model, and re-reads the
    /// permission rows. A re-run of a finished setup starts over — the
    /// finished stamp stays, so the launch gate never re-arms.
    func present() {
        if state.finishedAt != nil {
            step = .welcome
            completedSteps = []
            skippedSteps = []
        }
        state.presentedCount += 1
        save()
        seedingMirrors = true
        screenBarShown = model.screenBarShown()
        menuBarIconStyle = model.iconStyle()
        seedingMirrors = false
        Task { await refreshPermissions() }
    }

    // MARK: Navigation

    var canGoBack: Bool { step != .welcome }
    var canSkip: Bool { step.skippable }

    /// The primary button's word: Get Started → Next → Finish.
    var nextTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .done: return "Finish"
        default: return "Next"
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
        if step == .permissions { Task { await refreshPermissions() } }
    }

    func goBack() {
        guard canGoBack else { return }
        step = Step.allCases[step.index - 1]
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
    func finish() {
        completedSteps.insert(.done)
        if state.finishedAt == nil, state.whatsNewSeen == nil {
            state.whatsNewSeen = WhatsNewCatalog.releaseID
        }
        state.finishedAt = Date().timeIntervalSince1970
        save()
        onFinished?()
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
        state.whatsNewSeen = release
        persist(state)
    }

    /// The Done step's "Open Toys" — finishes like Finish and opens the
    /// Toys page too.
    func finishToToys() {
        finish()
        onOpenToys?()
    }

    // MARK: Agents step

    var monitorLive: Bool { model.monitorLive() }
    var agentRows: [SetupAgent] { model.agents() }

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
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hookNotes[provider] = nil }
        }
        hookNoteClear[provider] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    // MARK: Permissions step

    func status(of permission: SetupPermission) -> SetupPermissionStatus {
        statuses[permission] ?? .unknown
    }

    func refreshPermissions() async {
        statuses = await model.refreshPermissions()
    }

    /// The row's button: `act` runs the request or opens the pane, then
    /// the rows re-read their facts — a grant answers inside the prompt,
    /// a pane takes a moment to reflect a toggle.
    @discardableResult
    func act(on permission: SetupPermission) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            await self.model.act(permission)
            await self.refreshPermissions()
        }
    }

    /// A live dot while System Settings is open elsewhere: a slow
    /// re-probe, on only while the Permissions step is on screen.
    func startPermissionUpdates() {
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePermissionRefresh() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
        Task { await refreshPermissions() }
    }

    func stopPermissionUpdates() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func schedulePermissionRefresh() {
        Task { [weak self] in await self?.refreshPermissions() }
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
        let probed = await model.refreshPermissions()
        statuses = probed
        let review = PermissionHealth.review(remembered: state.grantedPermissions, statuses: probed)
        if review.remember != state.grantedPermissions {
            state.grantedPermissions = review.remember
            persist(state)
        }
        return review.lost
    }

    // MARK: Appearance step

    var iconPreview: SetupIconPreview { model.iconPreview() }
    var currentIconStyle: StatusIconStyle { StatusIconStyle(setting: menuBarIconStyle) }

    // MARK: Done step

    /// What's set and what still needs the user, in the order the steps ran.
    var summaryRows: [SummaryRow] {
        var rows: [SummaryRow] = []
        let agents = agentRows
        let hooked = agents.filter { $0.hookStatus == "ok" }
        if skippedSteps.contains(.agents) {
            rows.append(SummaryRow(symbol: "person.2.fill", text: "Agents",
                                   detail: "Skipped — Settings › Agents installs hooks any time.", ok: false))
        } else if !hooked.isEmpty {
            rows.append(SummaryRow(symbol: "person.2.fill", text: "Agents",
                                   detail: "\(hooked.count) provider\(hooked.count == 1 ? "" : "s") reporting.", ok: true))
        } else if agents.contains(where: { $0.detected == true }) {
            rows.append(SummaryRow(symbol: "person.2.fill", text: "Agents",
                                   detail: "Detected, hooks not installed yet — Settings › Agents.", ok: false))
        } else {
            rows.append(SummaryRow(symbol: "person.2.fill", text: "Agents",
                                   detail: "No agent CLIs found yet — install one and it appears in Settings › Agents.", ok: false))
        }

        let missing = SetupPermission.allCases.filter { status(of: $0) == .needed || status(of: $0) == .denied }
        if missing.isEmpty {
            rows.append(SummaryRow(symbol: "checkmark.shield.fill", text: "Permissions",
                                   detail: "Every row is granted or not applicable.", ok: true))
        } else {
            rows.append(SummaryRow(symbol: "exclamationmark.shield.fill", text: "Permissions",
                                   detail: "Still needed: " + missing.map(\.title).joined(separator: ", ") + ".", ok: false))
        }

        rows.append(SummaryRow(symbol: "menubar.rectangle", text: "Menu bar & Screen Bar",
                               detail: "\(currentIconStyle.title) icon · Screen Bar \(screenBarShown ? "on" : "off").",
                               ok: true))
        return rows
    }

    // MARK: Persistence

    /// Writes the current run's outcomes into the persisted state and
    /// through the injected `persist` — a tiny JSON, safe to write on
    /// every transition.
    private func save() {
        state.completedSteps = completedSteps.sorted { ($0.index) < ($1.index) }.map(\.rawValue)
        state.skippedSteps = skippedSteps.sorted { ($0.index) < ($1.index) }.map(\.rawValue)
        persist(state)
    }
}
