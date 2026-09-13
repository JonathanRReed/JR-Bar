import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Alcove (docs/TOYS.md): the notch island — a black capsule hugging the
/// notch that shows who's working and grows into a session card on
/// hover. Like Fold, someone renders it: JR-Bar's own island
/// (`AlcoveIslandWindow` + `AlcoveIslandView`, fed by `AlcoveIsland`'s
/// pure summary), or the capsule owned by an external app — Henrik's
/// Alcove or the open-source boring.notch — and then ours stays parked.
///
/// The Screen Bar's capsule-following (`AlcoveFollower`,
/// `screen_bar_follow_alcove`) is a different feature that only makes
/// sense while the Alcove app is the renderer, so its toggle lives
/// under that provider. The island's frame is always exactly its drawn
/// shape — an invisible window would sit over the menu bar swallowing
/// clicks.
@MainActor
@Observable
final class AlcoveToy: Toy {
    let core: CoreModel
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?
    /// Bumped on every app launch/terminate so the external-provider
    /// checks re-read `NSWorkspace`.
    private(set) var workspaceVersion = 0
    /// Bumped on display-parameter changes so the island reframes.
    private(set) var displayVersion = 0
    /// The island's hover state — the view reads it to pick its face,
    /// `setHovered` writes it.
    private(set) var islandExpanded = false
    /// Whether the island panel is ordered in — the view's pulse pauses
    /// on `false` so a parked island runs no clock at all.
    private(set) var islandVisible = false
    @ObservationIgnored private var island: AlcoveIslandWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(core: CoreModel, store: ToysStore) {
        self.core = core
        self.store = store
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.workspaceVersion += 1 }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayVersion += 1 }
        })
        observe()
        // The first pass: a toy that loads enabled must not wait for a
        // change to show its island.
        reconcile()
    }

    let id = "alcove"
    let name = "Alcove"
    let blurb = "A notch island: who's working, up in the notch. Alcove or Boring Notch can draw it instead."
    let symbol = "capsule.fill"

    var settings: AlcoveSettings { store?.state.alcove ?? AlcoveSettings() }

    var isOn: Bool {
        get { settings.enabled }
        set {
            store?.state.alcove.enabled = newValue
            store?.save()
            reconcile()
        }
    }

    // MARK: Status

    /// What the chip says — always a fact, never a promise.
    var status: ToyStatus {
        let settings = settings
        _ = workspaceVersion
        switch settings.provider {
        case .alcove:
            guard alcoveURL != nil else { return .unavailable("Alcove isn't installed") }
            guard settings.enabled else { return .off }
            return isAlcoveRunning
                ? .external("Alcove is rendering it")
                : .unavailable("Alcove isn't running")
        case .boringNotch:
            guard boringNotchURL != nil else { return .unavailable("Boring Notch isn't installed") }
            guard settings.enabled else { return .off }
            return isBoringNotchRunning
                ? .external("Boring Notch is rendering it")
                : .unavailable("Boring Notch isn't running")
        case .jrbar:
            if !settings.enabled { return .off }
            return settings.islandEnabled ? .on : .paused("Island hidden")
        }
    }

    // MARK: External providers

    var isAlcoveRunning: Bool {
        _ = workspaceVersion
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == AlcoveGeometry.bundleIdentifier }
    }

    var alcoveURL: URL? {
        _ = workspaceVersion
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: AlcoveGeometry.bundleIdentifier)
    }

    var isBoringNotchRunning: Bool {
        _ = workspaceVersion
        guard let id = boringNotchBundleID else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
    }

    /// boring.notch ships no bundle id we can pin, so it is read off the
    /// app's own Info.plist — the way `FoldToy.bendyURL` resolves Bendy.
    /// /Applications and ~/Applications are both probed, and a renamed
    /// install still resolves.
    private var boringNotchProbe: (id: String, path: URL)? {
        for folder in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for name in ["boring.notch.app", "Boring Notch.app", "boringNotch.app"] {
                let path = URL(fileURLWithPath: "\(folder)/\(name)")
                if let id = Bundle(url: path)?.bundleIdentifier {
                    return (id, path)
                }
            }
        }
        return nil
    }

    private var boringNotchBundleID: String? { boringNotchProbe?.id }

    var boringNotchURL: URL? {
        _ = workspaceVersion
        guard let probe = boringNotchProbe else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: probe.id) ?? probe.path
    }

    /// The URL the "Open" button launches for the chosen provider.
    var externalURL: URL? {
        switch settings.provider {
        case .jrbar: return nil
        case .alcove: return alcoveURL
        case .boringNotch: return boringNotchURL
        }
    }

    /// The picker's write path: choosing an external renderer parks our
    /// island and opens that app; JR-Bar just hands the notch back to
    /// `reconcile`.
    func setProvider(_ provider: AlcoveProvider) {
        store?.state.alcove.provider = provider
        store?.save()
        guard provider != .jrbar else {
            reconcile()
            return
        }
        parkIsland()
        if let url = externalURLFor(provider) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    private func externalURLFor(_ provider: AlcoveProvider) -> URL? {
        switch provider {
        case .jrbar: return nil
        case .alcove: return alcoveURL
        case .boringNotch: return boringNotchURL
        }
    }

    func openExternal() {
        guard let url = externalURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    // MARK: Island

    /// The capsule's contents, reduced by `AlcoveIsland` — the view reads
    /// this and `core.sessions` is observed, so it never sits stale.
    var islandSummary: AlcoveIslandSummary { AlcoveIsland.summarize(core.sessions) }

    /// The headline meters — empty while `showUsage` is off or the
    /// daemon sent no usage document.
    var islandMeters: [AlcoveIslandMeter] {
        settings.showUsage ? AlcoveIsland.meters(core.state?.usage) : []
    }

    /// The preferred screen's notch depth — the island's top clearance —
    /// re-measured whenever `displayVersion` bumps.
    var notchDepth: CGFloat {
        _ = displayVersion
        guard let screen = ScreenBarGeometry.preferredScreen() else { return 0 }
        return ScreenBarGeometry.notchDepth(of: screen)
    }

    /// The clearance the expanded card's content keeps under the notch —
    /// `AlcoveIslandLayout.expandedHeight` counts the same inset.
    var islandTopInset: CGFloat {
        notchDepth > 0 ? notchDepth + AlcoveIslandLayout.expandedNotchInset : 8
    }

    /// True while Fold's overlay is covering the screen — the island is
    /// invisible under it, so its window must let clicks fall through.
    var foldEngaged: Bool { store?.fold?.overlayOnScreen ?? false }

    /// The hover path: grow while the cursor is over the capsule, shrink
    /// when it leaves. "Grow on hover" off still lets the *shrink* half
    /// through — otherwise a capsule expanded when the toggle flipped
    /// could never collapse.
    func setHovered(_ hovering: Bool) {
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled else { return }
        let want = hovering && s.expandOnHover
        guard want != islandExpanded else { return }
        islandExpanded = want
        if let frame = islandFrame(expanded: want) {
            let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            island?.applyFrame(frame, animated: animated)
        }
    }

    /// The island's frame for its current face: centred on the notch
    /// slot, top edge pinned to the screen's top (or floating a few
    /// points under it on a notch-less screen).
    private func islandFrame(expanded: Bool) -> NSRect? {
        _ = displayVersion
        guard let screen = ScreenBarGeometry.preferredScreen() else { return nil }
        let slot = AlcoveIslandLayout.slot(left: screen.auxiliaryTopLeftArea,
                                           right: screen.auxiliaryTopRightArea)
        let depth = ScreenBarGeometry.notchDepth(of: screen)
        let centerX = slot?.centerX ?? screen.frame.midX
        let size: CGSize
        if expanded {
            let summary = islandSummary
            size = CGSize(width: AlcoveIslandLayout.expandedWidth,
                          height: AlcoveIslandLayout.expandedHeight(
                              notchDepth: depth,
                              rows: min(summary.rows.count, AlcoveIsland.rowLimit),
                              meters: islandMeters.count,
                              overflow: summary.rows.count > AlcoveIsland.rowLimit))
        } else {
            size = AlcoveIslandLayout.idleSize(
                slotWidth: slot?.width ?? 0, notchDepth: depth,
                contentWidth: AlcoveIsland.idleContentWidth(islandSummary))
        }
        return AlcoveIslandLayout.frame(
            screenFrame: screen.frame, centerX: centerX, size: size,
            topInset: slot == nil ? AlcoveIslandLayout.floatingTopInset : 0)
    }

    /// One place that reads the settings and makes the panel match:
    /// ordered in and framed while the island is ours, enabled and shown;
    /// fully ordered out otherwise — a parked island runs no timers.
    private func reconcile() {
        let s = settings
        guard s.enabled, s.provider == .jrbar, s.islandEnabled,
              let frame = islandFrame(expanded: islandExpanded) else {
            parkIsland()
            return
        }
        if island == nil { island = AlcoveIslandWindow(toy: self) }
        island?.applyFrame(frame, animated: false)
        if island?.isVisible != true {
            island?.orderFrontRegardless()
        }
        islandVisible = true
    }

    /// Ordered out and collapsed. The window object stays — a re-show is
    /// a frame, not a rebuild — but nothing in it ticks while hidden.
    private func parkIsland() {
        islandExpanded = false
        islandVisible = false
        island?.orderOut(nil)
    }

    /// One observation pass over every input, re-armed on each change —
    /// the same pattern `NotchBuddyToy.observeSessions` uses.
    private func observe() {
        withObservationTracking {
            _ = store?.state.alcove
            _ = core.sessions
            _ = core.state?.usage
            _ = displayVersion
            // islandExpanded is deliberately NOT tracked: `setHovered`
            // reframes the window itself, and a reconcile re-fired off
            // the same write would call `applyFrame(animated: false)`
            // mid-ease and snap it.
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcile()
                self.observe()
            }
        }
    }

    // MARK: Controls

    /// A binding into `store.state.alcove`; the store's `didSet`
    /// debounces the write.
    func bind<T>(_ keyPath: WritableKeyPath<AlcoveSettings, T>) -> Binding<T> {
        Binding(
            get: { self.store?.state.alcove[keyPath: keyPath] ?? AlcoveSettings()[keyPath: keyPath] },
            set: { self.store?.state.alcove[keyPath: keyPath] = $0 })
    }

    var providerBinding: Binding<AlcoveProvider> {
        Binding(
            get: { self.settings.provider },
            set: { self.setProvider($0) })
    }

    /// What the follower sees — the Capsule row under the Alcove provider.
    var capsuleFact: String {
        _ = workspaceVersion
        guard alcoveURL != nil else { return "not installed" }
        guard isAlcoveRunning else { return "Alcove isn't running" }
        if let capsule = store?.alcoveCapsule { return "following: \(Int(capsule.width.rounded())) pt wide" }
        return "running, no capsule seen"
    }

    var controls: AnyView {
        AnyView(AlcoveControlsView(toy: self))
    }
}

/// The card's disclosure body. Every toggle writes `store.state.alcove`
/// (which persists itself) except the provider picker, which goes
/// through `setProvider` so the swap can park our island and open theirs.
private struct AlcoveControlsView: View {
    let toy: AlcoveToy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: toy.providerBinding) {
                Text("JR-Bar").tag(AlcoveProvider.jrbar)
                Text("Alcove").tag(AlcoveProvider.alcove)
                Text("Boring Notch").tag(AlcoveProvider.boringNotch)
            } label: {
                SettingLabel(title: "Render with",
                             subtitle: "Let Alcove or Boring Notch draw the island instead.")
            }
            .pickerStyle(.menu)
            .fixedSize()

            providerNote
            providerControls
        }
    }

    /// The rows that belong to whoever renders: ours get the island's
    /// knobs, Alcove's keep the capsule-following that already existed,
    /// Boring Notch's get nothing — there is nothing of ours to set.
    @ViewBuilder
    private var providerControls: some View {
        switch toy.settings.provider {
        case .jrbar:
            Toggle(isOn: toy.bind(\.islandEnabled)) {
                SettingLabel(title: "Show the island",
                             subtitle: "The capsule under the notch.")
            }
            Toggle(isOn: toy.bind(\.expandOnHover)) {
                SettingLabel(title: "Grow on hover",
                             subtitle: "Hover expands it into the session card.")
            }
            Toggle(isOn: toy.bind(\.showUsage)) {
                SettingLabel(title: "Usage meters",
                             subtitle: "Per-provider quota bars inside the card.")
            }
        case .alcove:
            if let settings = toy.store?.settings {
                SettingToggle(settings, "Follow Alcove's capsule",
                              subtitle: "The Screen Bar matches the capsule's width while Alcove is up.",
                              path: "screen_bar_follow_alcove", default: true)
            }
            LabeledContent {
                Text(toy.capsuleFact)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } label: {
                SettingLabel(title: "Capsule", subtitle: "What the follower sees right now.")
            }
        case .boringNotch:
            EmptyView()
        }
    }

    /// What the chosen external renderer is doing — installed and
    /// launched, or a link to get it.
    @ViewBuilder
    private var providerNote: some View {
        switch toy.settings.provider {
        case .jrbar:
            EmptyView()
        case .alcove:
            externalNote(installed: toy.alcoveURL != nil, name: "Alcove",
                         link: URL(string: "https://alcove.app")!)
        case .boringNotch:
            externalNote(installed: toy.boringNotchURL != nil, name: "Boring Notch",
                         link: URL(string: "https://github.com/TheBoringNotch/boring.notch")!)
        }
    }

    private func externalNote(installed: Bool, name: String, link: URL) -> some View {
        HStack(spacing: 8) {
            Text(installed ? "\(name) is installed" : "\(name) isn't installed")
                .font(.callout)
                .foregroundStyle(.secondary)
            if installed {
                Button("Open \(name)") { toy.openExternal() }
            } else {
                Link("Get \(name)", destination: link)
                    .font(.callout)
            }
        }
    }
}
