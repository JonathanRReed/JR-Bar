import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Notch Buddy (docs/TOYS.md): a tiny creature in the `NotchHUD` panel
/// that lives by the agent state — asleep under a nightcap when nothing
/// runs, pacing while sessions work (bouncing in place when three or
/// more work at once), waving amber while an ask is open, tumbling into
/// a slump on a failure, one hop on a completion. Reads `core.sessions`
/// only; off by default.
///
/// It is also a small pet: the pill is clickable (the panel only
/// ignores the mouse while a toast holds it), a tap counts as a pet and
/// cycles a trick — hop, spin, wave, blush — and while an ask is open
/// the tap does something useful too: it opens the session asking. The
/// card can name it and feed it, completed sessions land as crumbs it
/// "eats", and a day without a pat leaves it drooping.
///
/// And it roams: a drag past four points lifts it out of the notch slot
/// and parks it anywhere on screen in a panel of its own (`freePosition`
/// survives relaunches, clamped onto the visible screen), a drop back on
/// the slot — or "Dock at the notch" — sends it home. Right-click or a
/// held press opens its menu; "Tuck away" hides it until the next
/// session event or a card re-enable. Floating, it wears a quiet
/// caption naming the session it is watching.
@MainActor
@Observable
final class NotchBuddyToy: Toy {
    let core: CoreModel
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?
    /// Something the panels need to re-lay out for changed: `isOn`,
    /// `tucked`, `freePosition`, `showCaption`.
    var onVisibilityChange: (@MainActor () -> Void)?
    /// Where home is, in screen coordinates — the HUD supplies it so
    /// "Float free" and a drop-on-the-notch know the dock slot.
    @ObservationIgnored var dockPointProvider: (@MainActor () -> CGPoint)?

    /// While non-nil and in the future the buddy hops once. Completions
    /// and treats both hop.
    private(set) var hopUntil: Date?
    /// When the current wave began — the ask entrance and the "!" pop
    /// once from here. `summary(at:)` maintains it because the view is
    /// the only clock that ticks the mood.
    private(set) var wavingSince: Date?
    /// When the current slump began — the tumble-in rolls once from
    /// here. Same deal as `wavingSince`: `summary(at:)` maintains it.
    private(set) var slumpedSince: Date?
    /// How many asks have opened. They alternate deterministically: odd
    /// asks wave with the "!" overhead, even asks just lean in and hold
    /// your eye.
    private(set) var waveOrdinal = 0
    /// How many taps have landed — the tricks cycle through the
    /// repertoire so repeated pats never repeat the same one twice.
    private(set) var trickOrdinal = 0
    /// Which trick is up this tap.
    private(set) var trickKind: BuddyTrick.Kind = .hop
    /// When the current trick began; the view ages it out.
    private(set) var trickStartedAt: Date?
    /// When the last treat landed — the hearts burst plays from here.
    private(set) var treatBurstAt: Date?
    /// When it last ate a completion crumb — the "+1" plays from here.
    private(set) var crumbAt: Date?
    /// -1 until the first sessions document lands: that one is the
    /// baseline — sessions already done when the app launches are
    /// history, not a feast.
    @ObservationIgnored private var lastDoneCount = -1

    init(core: CoreModel) {
        self.core = core
        observeSessions()
    }

    let id = "notch-buddy"
    let name = "Notch Buddy"
    let blurb = "A little guy in the notch who lives by what your agents are doing."
    let symbol = "face.smiling"

    /// On means showing: enabled and not tucked away. Flipping it back
    /// on from the card is also how a tucked buddy gets woken early.
    var isOn: Bool {
        get { (store?.state.notchBuddy.enabled ?? false) && !isTucked }
        set {
            store?.state.notchBuddy.enabled = newValue
            if newValue { store?.state.notchBuddy.tucked = false }
            onVisibilityChange?()
        }
    }

    var status: ToyStatus {
        if store?.state.notchBuddy.enabled != true { return .off }
        return isTucked ? .paused("Tucked away") : .on
    }

    var controls: AnyView {
        AnyView(BuddyControlsView(toy: self))
    }

    /// The roster pick, resolved through the settings' fallback — a file
    /// from a newer build keeps its string and reads as Dot here.
    var buddyCharacter: BuddyCharacter {
        store?.state.notchBuddy.resolvedCharacter ?? .dot
    }

    /// A binding into `store.state.notchBuddy.character` as the enum;
    /// the file keeps the raw string.
    var characterBinding: Binding<BuddyCharacter> {
        Binding(get: { self.buddyCharacter },
                set: { self.store?.state.notchBuddy.character = $0.rawValue })
    }

    /// The card's name field writes straight into the settings blob;
    /// blank keeps the character's own `defaultName`.
    var nameBinding: Binding<String> {
        Binding(get: { self.store?.state.notchBuddy.buddyName ?? "" },
                set: { self.store?.state.notchBuddy.buddyName = $0 })
    }

    /// Who the status line and the accessibility label name.
    var buddyName: String {
        store?.state.notchBuddy.resolvedName ?? buddyCharacter.defaultName
    }

    // MARK: Roaming

    /// Docked under the notch, or parked where the user dropped it.
    var freeSpot: BuddySpot? { store?.state.notchBuddy.freePosition }
    var isFree: Bool { freeSpot != nil }
    /// Tucked away: off the screen until the next session event (the
    /// session observer clears it) or `isOn` flips back on.
    var isTucked: Bool { store?.state.notchBuddy.tucked ?? false }
    /// The floating buddy's one-line tag under the pill.
    var showsCaption: Bool { store?.state.notchBuddy.showCaption ?? true }

    /// Where a drop landed it — the HUD moves it to the free panel.
    func parkFree(at point: CGPoint) {
        store?.state.notchBuddy.freePosition = BuddySpot(point)
        onVisibilityChange?()
    }

    /// Back under the notch — the menu's "Dock at the notch" and a drop
    /// on the slot both land here.
    func dock() {
        store?.state.notchBuddy.freePosition = nil
        onVisibilityChange?()
    }

    /// The undock with no drop point — the card's button parks it at the
    /// dock slot, where it can be dragged away from.
    func floatFree() {
        let fallback = NSScreen.main.map {
            CGPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.maxY - 60)
        }
        parkFree(at: dockPointProvider?() ?? fallback ?? CGPoint(x: 400, y: 700))
    }

    /// "Tuck away": hidden until the next thing happening or a card
    /// re-enable. The roster stays — it is a nap, not a farewell.
    func tuckAway() {
        store?.state.notchBuddy.tucked = true
        onVisibilityChange?()
    }

    func toggleCaption() {
        store?.state.notchBuddy.showCaption.toggle()
        onVisibilityChange?()
    }

    /// The floating caption: the session it is watching, or just its
    /// name tag while nothing is on the clock.
    func caption(at now: Date = Date()) -> String {
        summary(at: now).focus?.line ?? buddyName
    }

    // MARK: Drag

    /// The carry's life, panel-side bookkeeping the view reads: held,
    /// it leans toward the travel direction (`dragTilt`, settling via
    /// `dragMovedAt`) with its feet up; put down, `landedAt` plays a
    /// small squash. Reduce Motion ignores all of it.
    private(set) var isDragged = false
    private(set) var dragTilt: Double = 0
    private(set) var dragMovedAt: Date?
    private(set) var landedAt: Date?

    func dragStarted() {
        isDragged = true
        dragTilt = 0
        dragMovedAt = nil
        landedAt = nil
    }

    /// `dx` is this event's horizontal travel, not the total.
    func dragMoved(dx: Double, at now: Date = Date()) {
        guard isDragged else { return }
        dragTilt = BuddyPlacement.dragTilt(dx: dx)
        dragMovedAt = now
    }

    /// Put down — the landing beat plays from `landedAt`.
    func dragEnded(at now: Date = Date()) {
        isDragged = false
        dragTilt = 0
        landedAt = now
    }

    /// The carry was cut short (a toast took the panel): back to rest,
    /// no landing beat.
    func dragCancelled() {
        isDragged = false
        dragTilt = 0
    }

    // MARK: Interaction

    /// The longest-waiting ask — the tap-to-open pick and the menu's
    /// "Open". An embedded ask with no `openedAt` sorts as never-opened
    /// and lands last.
    var askingSession: CoreSession? {
        core.sessions
            .filter { SessionActivity.reduce($0) == .waiting }
            .min(by: { ($0.ask?.openedAt ?? .infinity) < ($1.ask?.openedAt ?? .infinity) })
    }

    /// While an ask is open the buddy is useful: this opens the session
    /// doing the asking — that is where the answer lives.
    @discardableResult
    func openAskingSession() -> Bool {
        guard let asking = askingSession else { return false }
        core.openSession(asking.id)
        return true
    }

    /// A tap on the buddy. Always a pet; unless Reduce Motion is on it
    /// also cycles a trick. And it is not just a trick machine: while an
    /// ask is open the tap opens the session doing the asking — that is
    /// where the answer lives.
    func tapped(at now: Date = Date()) {
        store?.state.notchBuddy.care.pet(at: now)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            trickKind = BuddyTrick.Kind.allCases[trickOrdinal % BuddyTrick.Kind.allCases.count]
            trickOrdinal += 1
            trickStartedAt = now
        }
        openAskingSession()
    }

    /// The card's "Give treat": fed for a while, hearts off the crown,
    /// and the hop borrowed from completions when motion is allowed.
    func giveTreat(at now: Date = Date()) {
        store?.state.notchBuddy.care.feed(at: now)
        treatBurstAt = now
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hopUntil = now.addingTimeInterval(1.1)
        }
    }

    /// The card's friendship line under the treat button.
    var careLine: String {
        guard let care = store?.state.notchBuddy.care else { return "" }
        let pets = care.petCount == 1 ? "1 pet" : "\(care.petCount) pets"
        let crumbs = care.crumbsEaten == 1 ? "1 crumb" : "\(care.crumbsEaten) crumbs"
        switch care.mood(at: Date()) {
        case .fed: return "Blissed out — \(pets), \(crumbs)"
        case .missing: return "Misses you — \(pets), \(crumbs)"
        case .content:
            if care.petCount == 0, care.crumbsEaten == 0 {
                return "Never petted. It doesn't mind yet."
            }
            return "\(pets) · \(crumbs)"
        }
    }

    // MARK: Mood

    /// What the buddy is doing, in `SessionActivity`'s precedence: a live
    /// ask outranks a failure, a failure outranks work, work outranks
    /// sleep. Three or more working sessions is a `gathering`, not a
    /// patrol. A completion hops once and then the mood falls back.
    enum Mood: String, Sendable {
        case asleep, pacing, gathering, waving, slumped, celebrating
    }

    /// Everything the HUD reads off the session list in one tick — the
    /// pose, the badge counts, the tints and the hover line — so a tick
    /// pays for a single pass over `core.sessions` and the pieces can
    /// never disagree with each other.
    struct BuddySummary {
        /// The pose: a live ask outranks a failure, a failure outranks
        /// work, work outranks sleep; three or more working is a
        /// `gathering`, and a completion's hop overrides it all.
        var mood = Mood.asleep
        /// Sessions doing work — the feet badge's number once it's plural.
        var working = 0
        /// Asks open right now — the "!" wears the count past one.
        var waiting = 0
        /// Failed runs in the list — the slump and the "failed" count.
        var failed = 0
        /// The provider running the most working sessions — the badge's
        /// tint. A split house still answers, and the tie breaks on the
        /// provider id so the pick can't flicker between ticks.
        var dominantProvider: String?
        /// The one provider running all the work, nil when two or more
        /// share it — the pacing tint falls back to the accent there.
        /// Ask, failed and hop keep their own colours regardless.
        var workingProvider: String?
        /// The provider display names on the clock, in session order —
        /// the hover line's tail.
        var providers: [String] = []
        /// What the buddy is called — the status line's subject.
        var name = ""
        /// How the friendship is doing — the pose's droop or blush.
        var care: BuddyCare.Mood = .content
        /// The one session it is watching — the "what is it doing" the
        /// status line's tail and the floating caption both read.
        var focus: BuddyFocus?
        /// The hover line: "Pixel is watching · 3 working · Claude ·
        /// rename-the-fish — waiting on you" — the name first, then
        /// who's on the clock, then what it's doing.
        var statusLine = ""
    }

    /// One pass over `core.sessions`: the mood, the counts, the tints
    /// and the hover line all fall out of the same
    /// `SessionActivity.reduce` calls. Also maintains the wave & slump
    /// clocks the one-off effects play from — the view's tick is the
    /// only clock that drives them.
    func summary(at now: Date = Date()) -> BuddySummary {
        var s = BuddySummary()
        var tally: [String: Int] = [:]
        var soleProvider: String?
        var splitWork = false
        for session in core.sessions {
            let activity = SessionActivity.reduce(session)
            switch activity {
            case .working:
                s.working += 1
                tally[session.provider, default: 0] += 1
                if let soleProvider, soleProvider != session.provider {
                    splitWork = true
                } else if soleProvider == nil {
                    soleProvider = session.provider
                }
            case .waiting: s.waiting += 1
            case .failed: s.failed += 1
            case .done, .ended, .idle: break
            }
            switch activity {
            case .working, .waiting, .failed:
                let name = ProviderStyle.style(for: session.provider).name
                if !s.providers.contains(name) { s.providers.append(name) }
            case .done, .ended, .idle: break
            }
        }
        s.dominantProvider = tally.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
        s.workingProvider = splitWork ? nil : soleProvider
        if s.waiting > 0 { s.mood = .waving }
        else if s.failed > 0 { s.mood = .slumped }
        // Three or more working at once: busy is exciting, not calm.
        else if s.working >= 3 { s.mood = .gathering }
        else if s.working > 0 { s.mood = .pacing }
        if let hopUntil, now < hopUntil { s.mood = .celebrating }
        if s.mood == .waving {
            if wavingSince == nil { wavingSince = now; waveOrdinal += 1 }
        } else if wavingSince != nil {
            wavingSince = nil
        }
        if s.mood == .slumped {
            if slumpedSince == nil { slumpedSince = now }
        } else if slumpedSince != nil {
            slumpedSince = nil
        }
        s.care = store?.state.notchBuddy.care.mood(at: now) ?? .content
        s.name = buddyName
        s.focus = BuddyFocus.pick(from: core.sessions)
        var parts: [String] = []
        if s.working > 0 { parts.append("\(s.working) working") }
        if s.waiting > 0 { parts.append("\(s.waiting) waiting") }
        if s.failed > 0 { parts.append("\(s.failed) failed") }
        if parts.isEmpty {
            s.statusLine = s.care == .missing
                ? "\(s.name) misses you — tap it to say hi."
                : "\(s.name) is asleep."
        } else {
            var line = "\(s.name) is watching · " + parts.joined(separator: " · ")
            // The glance answers what it is doing, not just how many:
            // the focus names the one session that matters; the
            // providers tail only earns its place when the clock is
            // split across two or more — a lone provider is already
            // named inside the focus line.
            if s.providers.count > 1 { line += " · " + s.providers.joined(separator: ", ") }
            if let focus = s.focus { line += " · \(focus.line)" }
            if s.care == .missing { line += " · misses you" }
            s.statusLine = line
        }
        return s
    }

    // MARK: Menu

    /// The press-and-hold / right-click menu. `NSMenuItem.target` is
    /// weak, so the handler object lives on the toy and is re-aimed at
    /// every build — the menu itself only exists for the pop.
    @ObservationIgnored private let menuActions = BuddyMenuActions()
    @ObservationIgnored private var renamePanel: BuddyRenamePanel?

    /// The pet menu: pet it, feed it, rename it, swap characters, open
    /// the asking session while one is up, dock or float it, toggle the
    /// caption, tuck it away. `panelFrame` is where the buddy sits when
    /// the menu opened, so "Float free" parks it in place.
    func actionMenu(panelFrame: NSRect?) -> NSMenu {
        menuActions.toy = self
        menuActions.panelFrame = panelFrame
        let menu = NSMenu()
        menu.addItem(menuActions.item(title: "Pet it", action: #selector(BuddyMenuActions.pet)))
        menu.addItem(menuActions.item(title: "Give treat", action: #selector(BuddyMenuActions.treat)))
        menu.addItem(menuActions.item(title: "Rename…", action: #selector(BuddyMenuActions.rename)))
        let roster = NSMenu()
        for character in BuddyCharacter.allCases {
            let item = menuActions.item(title: character.displayName,
                                        action: #selector(BuddyMenuActions.pickCharacter))
            item.representedObject = character.rawValue
            item.state = character == buddyCharacter ? .on : .off
            roster.addItem(item)
        }
        let rosterItem = NSMenuItem(title: "Change character", action: nil, keyEquivalent: "")
        rosterItem.submenu = roster
        menu.addItem(rosterItem)
        menu.addItem(.separator())
        if let asking = askingSession {
            let label = SessionLabel.display(label: asking.label, shortId: asking.shortId,
                                           id: asking.id, provider: asking.provider)
            menu.addItem(menuActions.item(title: "Open “\(label)”",
                                          action: #selector(BuddyMenuActions.openAsk)))
        }
        menu.addItem(menuActions.item(title: isFree ? "Dock at the notch" : "Float free",
                                      action: #selector(BuddyMenuActions.toggleDock)))
        let captionItem = menuActions.item(title: "Show caption",
                                           action: #selector(BuddyMenuActions.toggleCaption))
        captionItem.state = showsCaption ? .on : .off
        menu.addItem(captionItem)
        menu.addItem(.separator())
        menu.addItem(menuActions.item(title: "Tuck away", action: #selector(BuddyMenuActions.tuck)))
        return menu
    }

    /// "Rename…" opens a small floating field under the pill; `frame` is
    /// where the buddy sits so the prompt lands next to it.
    func promptRename(near frame: NSRect?) {
        if renamePanel == nil { renamePanel = BuddyRenamePanel() }
        renamePanel?.present(near: frame, current: store?.state.notchBuddy.buddyName ?? "",
                             placeholder: buddyCharacter.defaultName) { [weak self] name in
            self?.nameBinding.wrappedValue = name
        }
    }

    private static func doneCount(in sessions: [CoreSession]) -> Int {
        sessions.filter { SessionActivity.reduce($0) == .done }.count
    }

    /// Watches the session list like `AppDelegate.observeCore`: one
    /// observation per change, coalesced into a main-queue turn. A rising
    /// done count is a completion, so the buddy hops once — and eats the
    /// completion as a crumb, which is as close to hunger as a menu-bar
    /// pet gets.
    private func observeSessions() {
        withObservationTracking {
            _ = core.sessions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date()
                let done = Self.doneCount(in: self.core.sessions)
                if self.lastDoneCount >= 0 {
                    // The first document is the baseline — history, not
                    // an event. Anything after it is something happening,
                    // and something happening is what a tucked-away buddy
                    // waits for.
                    if self.store?.state.notchBuddy.tucked == true {
                        self.store?.state.notchBuddy.tucked = false
                        self.onVisibilityChange?()
                    }
                    if done > self.lastDoneCount {
                        self.hopUntil = now.addingTimeInterval(1.1)
                        self.crumbAt = now
                        self.store?.state.notchBuddy.care.eat(at: now, count: done - self.lastDoneCount)
                    }
                }
                self.lastDoneCount = done
                self.observeSessions()
            }
        }
    }
}

/// The card's disclosure body: the roster picker (a menu, like the Fold
/// card's "Render with"), a live strip — every buddy pacing in place,
/// the picked one lit, tap to choose — then the pet half: a name field
/// (blank keeps the character's own), a "Give treat" button that bursts
/// hearts over the button and the buddy alike, and the friendship line.
private struct BuddyControlsView: View {
    let toy: NotchBuddyToy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: toy.characterBinding) {
                ForEach(BuddyCharacter.allCases, id: \.self) { c in
                    Text(c.displayName).tag(c)
                }
            } label: {
                SettingLabel(title: "Character", subtitle: "Who lives in your notch.")
            }
            .pickerStyle(.menu)
            .fixedSize()

            roster

            LabeledContent {
                TextField("", text: toy.nameBinding, prompt: Text(toy.buddyCharacter.defaultName))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            } label: {
                SettingLabel(title: "Name", subtitle: "What it answers to. Blank keeps \(toy.buddyCharacter.defaultName).")
            }

            HStack(spacing: 10) {
                Button("Give treat") { toy.giveTreat() }
                    .controlSize(.small)
                    .overlay(alignment: .top) { treatHearts }
                Text(toy.careLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Roaming state at a glance: a wake-up call while tucked, a
            // dock button while it floats, and an undock that parks it
            // at the slot while docked (from there, drag it anywhere).
            if toy.isTucked {
                HStack(spacing: 10) {
                    Button("Bring it back") { toy.isOn = true }
                        .controlSize(.small)
                    Text("Tucked away until the next event.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(toy.isFree ? "Dock at the notch" : "Float free") {
                    toy.isFree ? toy.dock() : toy.floatFree()
                }
                .controlSize(.small)
            }
        }
    }

    /// The treat's hearts, replayed over the button — the buddy in the
    /// notch gets its own burst from the same clock. Reads
    /// `toy.treatBurstAt` in the body so the press itself re-renders.
    private var treatHearts: some View {
        let burstAt = toy.treatBurstAt
        return TimelineView(.animation(paused: reduceMotion
                                       || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { context in
            let age = burstAt.map { context.date.timeIntervalSince($0) } ?? .infinity
            ZStack {
                if age < 0.9 {
                    ForEach(0..<3, id: \.self) { i in
                        let p = min(1, max(0, (age - Double(i) * 0.09) / 0.65))
                        Image(systemName: "heart.fill")
                            .font(.system(size: [4.5, 6.0, 5.0][i], weight: .bold))
                            .foregroundStyle(.pink)
                            .offset(x: [-7.0, 0.5, 7.0][i], y: -4 - p * 15)
                            .opacity(p <= 0 ? 0 : (p > 0.55 ? (1 - p) / 0.45 : 0.95))
                    }
                }
            }
        }
    }

    /// One cell per character, all on the same clock, all in the idle
    /// patrol pose. Reduce Motion stills the strip — pose stays — and
    /// the paused schedule keeps a stilled strip from ticking at all.
    private var roster: some View {
        TimelineView(.animation(paused: reduceMotion
                                || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { context in
            HStack(spacing: 5) {
                ForEach(BuddyCharacter.allCases, id: \.self) { c in
                    cell(c, at: context.date)
                }
            }
        }
    }

    private func cell(_ c: BuddyCharacter, at now: Date) -> some View {
        let selected = toy.characterBinding.wrappedValue == c
        return BuddyFigure(character: c, mood: .pacing, tint: .accentColor,
                           phase: now.timeIntervalSince1970, hopProgress: nil,
                           waveAge: nil, slumpAge: nil, leans: false,
                           still: reduceMotion, askCount: 0, care: .content,
                           trick: nil, treatAge: nil, crumbAge: nil)
            .frame(width: 18, height: 18)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture { toy.characterBinding.wrappedValue = c }
            .help("\(c.displayName) — \(c.blurb)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(c.displayName)\(selected ? ", selected" : "")")
    }
}

/// Target object for the buddy's menu — `NSMenuItem.target` is weak, so
/// the toy keeps this alive and re-aims it each time the menu is built.
@MainActor
final class BuddyMenuActions: NSObject {
    weak var toy: NotchBuddyToy?
    /// Where the buddy sits right now — "Float free" parks it there.
    var panelFrame: NSRect?

    func item(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func pet(_ sender: Any?) { toy?.tapped() }
    @objc func treat(_ sender: Any?) { toy?.giveTreat() }
    @objc func rename(_ sender: Any?) { toy?.promptRename(near: panelFrame) }

    @objc func pickCharacter(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        toy?.store?.state.notchBuddy.character = raw
    }

    @objc func openAsk(_ sender: Any?) { toy?.openAskingSession() }

    @objc func toggleDock(_ sender: Any?) {
        guard let toy else { return }
        if toy.isFree {
            toy.dock()
        } else if let panelFrame {
            toy.parkFree(at: CGPoint(x: panelFrame.midX, y: panelFrame.midY))
        } else {
            toy.floatFree()
        }
    }

    @objc func toggleCaption(_ sender: Any?) { toy?.toggleCaption() }
    @objc func tuck(_ sender: Any?) { toy?.tuckAway() }
}
