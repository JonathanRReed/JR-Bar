import AppKit
import ApplicationServices
import CoreGraphics
import JRBarCore
import Observation
import SwiftUI

/// The Menu Bar utility under the macOS 27 concealer: the icon's mirror,
/// the concealed plan, escapees and lifts, and the glyph camera.
extension MenuBarUtility {
    // MARK: The concealer (macOS 27)

    /// Bring the agent-side engine up: the hider keeps listing and
    /// planning (the card, the Item Bar, the reveal clock all read its
    /// plan) but never grows a spacer or draws a cover; the plan's
    /// sections come from the per-app map; the bridge takes the
    /// system's clicks; the mirror carries the icon.
    func startConcealer() {
        // One engine at a time: a second start would overwrite the first
        // engine's bridge and helper without stopping them, leaving a
        // live event tap pointing at a freed bridge.
        guard concealer == nil else { return }
        runningApps.invalidate()
        let concealer = MenuBarConcealer()
        concealer.onChange = { [weak self] in self?.concealerChanged() }
        self.concealer = concealer
        concealerStartedAt = Date()
        prePhotographPending = true
        hider.shuttersSuppressed = true
        // No affordance under the agent: nothing of ours grows while the
        // agent hides — the icon is the mirror's.
        host?.setBoundarySpacer(0)
        let bridge = MenuBarSystemClickBridge { [weak self] point in
            self?.bridgeClick(at: point)
        }
        bridge.start()
        clickBridge = bridge
        clickBridgeFailed = !bridge.tapLive
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.noteWorkspaceChange()
                }
            })
        }
        MenuBarAssessmentBackend.log.notice("conceal: engine up (MenuBarClientCore resolved)")
        installBoundary()
        refreshBoundary()
        iconMirror = makeIconMirror()
        updateIconMirror()
        menuHandleChanged()
        // The spacers stand down and the extras move onto the mirror.
        if running { syncExtras() }
    }

    /// The mirror's frame while it stands; nil while it is down.
    var standingMirrorFrame: NSRect? {
        iconMirror.flatMap { $0.isVisible ? $0.frame : nil }
    }

    /// The ear's ‹ (`menuHandleRevealed`) may have changed: the mirror
    /// took or gave back the icon, the hidden run flipped, the engine
    /// came up or went down. The band otherwise saw these only on its
    /// 1 Hz safety poll, and for up to about 1.25 s two ‹ marks stood —
    /// the mirror's and the ear's — or none did. It rides the ear-limit
    /// push, whose debounced rescan compares the handle too.
    func menuHandleChanged() {
        ScreenBarGeometry.earLimitsChanged?()
    }

    /// The mirror moved, resized, came up or went down. The covers the
    /// hider paints this pass were cut against its frame from before it
    /// settled: `onPlan` builds the cover runs before `syncConcealer`
    /// seats the mirror, and a face change re-seats it with no plan at
    /// all. A merged run could then span the new seat, and a shutter at
    /// the mirror's own level paint over the icon until the next scan.
    /// One reconcile on the next run-loop turn re-cuts them around the
    /// settled frame. Only one: a seat that moves again inside that pass
    /// waits for the next pass of its own, so a re-cut never chains.
    private func recutCovers() {
        guard !coverRecutQueued, !coverRecutRunning else { return }
        coverRecutQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.coverRecutQueued = false
            guard self.concealer != nil else { return }
            self.coverRecutRunning = true
            self.hider.reconcile()
            self.coverRecutRunning = false
        }
    }

    /// The mirror, wired the way the real button is: the face's click is
    /// the panel, its right/Option click the item's full menu, the ‹ the
    /// hidden run's toggle. Internal so a test can drive the wiring
    /// without an engine.
    func makeIconMirror() -> MenuBarIconMirror {
        let mirror = MenuBarIconMirror()
        mirror.onPrimaryClick = { [weak self] in self?.host?.faceClicked() }
        mirror.onSecondaryClick = { [weak self] view in self?.host?.popUpMenu(in: view) }
        mirror.onChevronClick = { [weak self] in self?.host?.onBoundaryClick?() }
        mirror.onPlace = { [weak self] frame in self?.host?.mirroredFaceFrame = frame }
        mirror.onAccessoryClick = { [weak self] id, view in self?.accessoryClicked(id, view: view) }
        if let face = mirrorFace() { mirror.update(face: face) }
        return mirror
    }

    /// When the mirror carries the icon: the engine is up, the style
    /// draws an icon, and something is (or is about to be) concealed —
    /// the assertion is live, a click-bridge lift is only a suspend, or
    /// the engine has a target it is still asserting (the first 2.5 s
    /// after start, while a relaunch's old assertion drains, or an
    /// activation in flight). A target the engine keeps failing to
    /// assert is not about to be concealed: nothing holds, macOS draws
    /// the real item, and a mirror would only blank it. Otherwise no
    /// assertion holds and macOS draws the real item itself. Pure so a
    /// test pins the table.
    nonisolated static func mirrorsIcon(engineUp: Bool, styleDrawsIcon: Bool, concealing: Bool,
                                        suspended: Bool, targetEmpty: Bool,
                                        activationFailing: Bool = false) -> Bool {
        engineUp && styleDrawsIcon
            && (concealing || (!activationFailing && (suspended || !targetEmpty)))
    }

    /// The set the engine converges to: the map's hidden apps less the
    /// live reveal — our own family never, whatever a stale map says
    /// (the daemon's meter hid itself once).
    private func concealTarget() -> Set<String> {
        let now = Date()
        lifts = lifts.filter { $0.value > now }
        return Self.liveTarget(
            MenuBarConcealPlan.concealed(apps: liveSettings().concealedApps, revealed: hider.revealed),
            lifts: lifts, now: now)
    }

    /// The target with the live lifts left out — never our own family.
    /// Pure so a test pins it.
    nonisolated static func liveTarget(_ concealed: Set<String>, lifts: [String: Date],
                                       now: Date) -> Set<String> {
        concealed.filter { !isOwnFamily($0) && !(lifts[$0].map { $0 > now } ?? false) }
    }

    /// How long a lift holds for its photograph — the camera's two
    /// frames and their listings, with room to spare; the pass ends it
    /// sooner.
    nonisolated static let liftPhotographHold: TimeInterval = 3

    /// Stand `app` alone on the row until `until` (a later lift wins),
    /// and converge now.
    func lift(_ app: String, until: Date) {
        lifts[app] = max(until, lifts[app] ?? until)
        syncConcealer()
    }

    /// End a lift once nothing of the app's is open — a menu the person
    /// is reading keeps it standing, polled each second for up to five
    /// minutes — then put the full target back.
    func releaseLift(_ app: String, item: MenuBarItem) async {
        for _ in 0..<300 {
            guard MenuBarItemLister.menuOpen(ownerPIDs: [item.ownerPID],
                                             infos: MenuBarItemLister.windowInfos()) else { break }
            lifts[app] = Date().addingTimeInterval(2)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // The press is answered and its menu closed, and the lift still
        // stands the item on the row: the moment to photograph a stale
        // glyph. Never before the press — each frame lights the
        // recording indicator and shifts the bar, which must not land
        // between a click and the menu it opens. A fresh glyph costs no
        // capture at all. Only a lift still standing is held — one that
        // already lapsed is not raised again for a picture.
        if let camera = glyphCamera, let until = lifts[app], until > Date() {
            lifts[app] = max(until, Date().addingTimeInterval(Self.liftPhotographHold))
            let stored = await camera.photograph([item], rows: MenuBarItemLister.menuBarRows())
            if !stored.isEmpty { bar.glyphsChanged(); refreshEarFeed() }
        }
        lifts[app] = nil
        runningApps.invalidate()
        syncConcealer()
    }

    /// Settle who draws the icon and, while the mirror does, where it
    /// stands. Runs on every plan pass and every engine change; the
    /// window moves only when its frame does, and a frame that changed
    /// re-cuts the covers.
    func updateIconMirror() {
        guard let concealer else { return }
        let before = standingMirrorFrame
        // A target of apps that are not running conceals nothing — the
        // engine drops the assertion and macOS draws the real item.
        // A style that draws no icon still stands a mirror while the
        // extras ride it — they have nowhere else to show.
        let drawsSomething = (host?.anchorWantsVisibleSeat ?? false)
            || !(iconMirror?.face.accessories.isEmpty ?? true)
        let mirrored = Self.mirrorsIcon(engineUp: true,
                                        styleDrawsIcon: drawsSomething,
                                        concealing: concealer.isConcealing,
                                        suspended: concealer.isSuspended,
                                        targetEmpty: concealTarget().isDisjoint(with: runningApps.snapshot()),
                                        activationFailing: concealer.activationFailing)
        let extrasFlipped = iconMirrored != mirrored
        iconMirrored = mirrored
        host?.setFaceMirrored(mirrored)
        if extrasFlipped {
            // The extras' real items blank or wear their faces again.
            if settings().combinedSystemItem { combinedItem.sync(blank: extrasMirrored) }
            syncAgentItem()
        }
        stepCombinedGate()
        if mirrored, let mirror = iconMirror, let primary = NSScreen.screens.first {
            mirror.show(row: Self.primaryRow(), primaryMaxY: primary.frame.maxY) { width in
                mirrorSeat(width: width)
            }
        } else {
            iconMirror?.hide()
        }
        if standingMirrorFrame != before { recutCovers() }
    }

    /// The menu bar's row on the Quartz origin display — the one the
    /// mirror stands on. `menuBarRow()` takes its depth from
    /// `NSScreen.main`, the key window's screen: with an external
    /// display in front the notch's 37-pt row reads as 24, which would
    /// seat the mirror 6.5 pt high.
    static func primaryRow() -> CGRect {
        MenuBarItemLister.menuBarRows().first ?? MenuBarItemLister.menuBarRow()
    }

    /// The host redrew its face — style, tint, tooltip, highlight,
    /// pulse, the hidden run's count. The mirror wears it and re-seats
    /// (a label or the ‹ changes its width); a flip to or from the
    /// `.hidden` style settles whether it stands at all.
    func faceChanged() {
        guard concealer != nil, let face = mirrorFace() else { return }
        iconMirror?.update(face: face)
        updateIconMirror()
    }

    /// The mirror's left edge for a `width`-wide panel: flush left of
    /// the first drawn item, from the right, with room to stand — the
    /// right end of the blank run the concealed apps leave — or, on a
    /// bar with no such room, `MenuBarIconMirror.seat`'s fallbacks,
    /// which cover as little of any drawn item as they can. Drawn is
    /// every listed item on the main row that is not ours and not
    /// concealed, the native « included. While no assertion holds (a
    /// bridged click's lift, the start grace) the target counts as
    /// concealed, so a 0.45 s reflow never walks the icon — unless the
    /// engine is failing to assert it: then macOS draws every target
    /// app, and a seat that skipped them would stand on one.
    private func mirrorSeat(width: CGFloat) -> CGFloat {
        let row = Self.primaryRow()
        let clear = mirrorClearOf()
        let targetOnItsWay = concealer.map { !$0.isConcealing && !$0.activationFailing } ?? true
        let concealed = targetOnItsWay ? concealTarget() : (concealer?.concealedApps ?? [])
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let drawn = (lastPlan.shown + lastPlan.hidden + lastPlan.alwaysHidden).filter { item in
            item.ownerPID != ourPID && Self.isForeignOwner(item.ownerName)
                && item.bounds.intersects(row)
                && !(item.bundleID.map { concealed.contains($0) } ?? false)
        }.map(\.bounds)
        let seat = MenuBarIconMirror.seat(drawn: drawn, clearOf: clear, width: width, rowMaxX: row.maxX)
        if seat != lastMirrorSeat {
            lastMirrorSeat = seat
            let line = "conceal: mirror seat \(String(format: "%.0f", seat)) w=\(String(format: "%.0f", width)) clear of \(String(format: "%.0f", clear)), \(drawn.count) drawn"
            // A seat on a drawn item hides that app's icon and takes its
            // clicks: no gap on the row fits the face. Said at notice so
            // a crowded bar's overlap shows in the log.
            let covered = drawn.filter { $0.minX < seat + width && $0.maxX > seat }.count
            if covered > 0 {
                MenuBarAssessmentBackend.log.notice("\(line, privacy: .public) — stands on \(covered, privacy: .public), no gap fits")
            } else {
                MenuBarAssessmentBackend.log.debug("\(line, privacy: .public)")
            }
        }
        return seat
    }

    /// Where nothing covers the row on the Quartz origin display. The
    /// mirror seats, and the reveal zone starts, right of it.
    func mirrorClearOf() -> CGFloat {
        guard let primary = NSScreen.screens.first else { return 0 }
        return Self.mirrorClearOf(
            notch: primary.auxiliaryTopRightArea?.minX,
            covering: ScreenBarGeometry.coveringScreenRect.flatMap { rect in
                primary.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) ? rect.maxX : nil
            },
            appMenuEdge: MenuBarItemLister.appMenuEdge,
            row: Self.primaryRow())
    }

    /// The furthest right of: the notch's right edge; our band's (or
    /// island's) right edge — the band window claims its ears' full
    /// extent; and the front app's last menu title. The menus are not
    /// in the listing, so without their edge a crowded bar's seat (or a
    /// notch Mac's menus spilling past the notch) lands the mirror on
    /// them — a status-bar-level panel taking their clicks — and the
    /// reveal zone starts on them. The menu edge is the front app's on
    /// whichever bar it drew; one outside the origin display's `row`
    /// would push the seat off it, so only an edge inside counts. Pure
    /// so a test pins it.
    nonisolated static func mirrorClearOf(notch: CGFloat?, covering: CGFloat?,
                                          appMenuEdge: CGFloat?, row: CGRect) -> CGFloat {
        let menus = appMenuEdge.flatMap { $0 > row.minX && $0 < row.maxX ? $0 : nil }
        return max(notch ?? 0, covering ?? 0, menus ?? 0, 0)
    }

    /// A workspace launch or terminate under the concealer: refresh
    /// the running universe and re-apply. The concealer's allowlist is
    /// monotonic — a first-seen app joins it and the union re-assert
    /// shows it without dropping anything; a quit changes nothing. No
    /// suspend: the bar never lifts for a launch — the steady-state
    /// `conceal: released` churn the old adoption beat caused several
    /// times an hour. Suspending survives only where a click must
    /// physically land: the bridged system items.
    func noteWorkspaceChange() {
        runningApps.invalidate()
        syncConcealer()
    }

    func stopConcealer() {
        guard let concealer else { return }
        iconMirrored = false
        iconMirror?.hide()
        iconMirror = nil
        lastMirrorSeat = nil
        // The real item is the icon again, at its natural width.
        host?.setFaceMirrored(false)
        runningApps.invalidate()
        // The drop lands now — a disable or quit must not leave the
        // run concealed for the drain; `releaseAll` invalidates the
        // live assertion synchronously, then unwinds queued work.
        Task { await concealer.releaseAll() }
        clickBridge?.stop()
        clickBridge = nil
        clickBridgeFailed = false
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        hider.shuttersSuppressed = false
        hider.externalPlan = nil
        self.concealer = nil
        menuHandleChanged()
        // The real extras are the faces again; the spacers come back.
        if running { syncExtras() }
    }

    /// The bundle identifiers of every running app — the allowlist's
    /// universe. An app that launches later is re-applied for by the
    /// workspace observers.
    static func readRunningBundleIDs() -> Set<String> {
        var ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        // Ourselves, always: the workspace list can omit the current
        // process, and an allowlist without us concealed our own icon.
        if let own = Bundle.main.bundleIdentifier { ids.insert(own) }
        return ids
    }

    /// The assertion only adopts items that exist when it activates —
    /// a concealed app that re-creates its status item afterwards
    /// stands on the row until the next activation (Tailscale's grid,
    /// ChatGPT's knot and cmux sat drawn in the "should be empty"
    /// stretch doing exactly that). A newly standing concealed bundle
    /// earns a fresh activation, rate-limited so churn cannot flap the
    /// bar; a throttled escape stays out of the baseline so the next
    /// scan retries it.
    func watchConcealedEscapees(in listing: MenuBarHidePlan) {
        // A suspend is a lift, not a teardown — the assertion is off but
        // coming back, so the bookkeeping (first-seen clocks, standings,
        // pixel verdicts) must survive the window or every Item Bar open
        // restarts the ~60 s classification from zero.
        guard let concealer, concealer.isConcealing || concealer.isSuspended else {
            concealedStanding = []
            escapeFirstSeen = [:]
            escapeStandings = [:]
            resistantConcealed = []
            pendingResistance = []
            pixelDisproven = []
            concealLiveSince = .distantPast
            lastConcealedFrames = [:]
            concealedGhostFrames = [:]
            liveConcealedItems = [:]
            return
        }
        guard hider.revealed.isEmpty else { return }
        // Every display's bar counts — an item standing on a secondary
        // screen's strip is just as visible as one on the main row.
        let rows = MenuBarItemLister.menuBarRows()
        let all = listing.shown + listing.hidden + listing.alwaysHidden
        // Same on-row rule the hider plans by: an item parked under
        // the « control reports its frame, not a row position.
        let overflowFrames = all
            .filter { item in item.isNativeOverflowControl
                && rows.contains { $0.intersects(item.bounds) } }
            .map(\.bounds)
        // The live target, not the persisted setting: `trigger(_:)`
        // narrows the assertion for the scoped reveal, and the revealed
        // app must not classify as an escapee while the user reads it —
        // that re-conceals the item under its open menu. During a
        // suspend the live set is empty, so nothing counts as escaped
        // while everything legitimately stands.
        let concealedIDs = concealer.concealedApps
        let concealedItems = all.filter { item in
            item.bundleID.map { concealedIDs.contains($0) } ?? false
        }
        // What reads as "standing" is almost always the ghost: the
        // agent takes the item's pixels but not its Accessibility
        // node, so the node keeps reporting a frame — frozen, or one
        // it was relayouted to — pressable, undrawn. The only listing
        // evidence a live registration offers is a move to an on-row
        // slot the ghost never reported.
        let frames = Dictionary(concealedItems.map { ($0.id, $0.bounds) },
                                uniquingKeysWith: { first, _ in first })
        let onRowIDs = Set(concealedItems.filter { item in
            rows.contains { $0.intersects(item.bounds) }
                && !overflowFrames.contains(where: { $0.intersection(item.bounds).width >= 4 })
        }.map(\.id))
        let now = Date()
        // Ids mid-classification keep their proof past the decay window —
        // the standings rule takes ~60 s and must not be reset by it.
        let classifying = Set(escapeFirstSeen.keys)
            .union(escapeStandings.keys).union(pendingResistance)
        let triage = Self.concealedEscapees(
            onRow: onRowIDs, frames: frames, previous: lastConcealedFrames,
            ghostHistory: concealedGhostFrames, proven: liveConcealedItems, now: now,
            retain: classifying)
        liveConcealedItems = triage.proven
        concealedGhostFrames = triage.ghostHistory
        lastConcealedFrames = frames
        var standing = Set<String>()
        for item in concealedItems
            where liveConcealedItems[item.id] != nil && onRowIDs.contains(item.id) {
            if let id = item.bundleID { standing.insert(id) }
        }
        if concealLiveSince == .distantPast { concealLiveSince = now }
        // Still settling the last activation — keep the baseline stale
        // so the first post-grace scan catches whatever stood through it.
        guard now.timeIntervalSince(concealLiveSince) >= 1.2 else { return }
        let escaped = standing.subtracting(concealedStanding)
        let throttled = now.timeIntervalSince(lastReassert) <= 1.5
        concealedStanding = throttled ? standing.subtracting(escaped) : standing
        for id in standing where escapeFirstSeen[id] == nil {
            escapeFirstSeen[id] = now
        }
        for id in escapeFirstSeen.keys where !standing.contains(id) {
            escapeFirstSeen[id] = nil
        }
        for id in escapeStandings.keys where !standing.contains(id) {
            escapeStandings[id] = nil
        }
        for id in pixelDisproven where !standing.contains(id) {
            pixelDisproven.remove(id)
        }
        // `resistantConcealed` deliberately does NOT clear when an
        // escapee leaves the row: the agent holding it for a beat does
        // not make it takeable — it re-escapes on the same cadence
        // (cmux's ~20 s flap), and a cleared proof leaves every escape
        // window standing uncovered through a fresh 8-second wait.
        // Once an item proves agent-proof it keeps the cover for the
        // rest of this concealment session; the set resets wholesale
        // when the assertion lifts (the guard above).
        // Eight seconds standing through the re-assert it triggered —
        // the agent had its chance. Then PIXELS decide: a live item's
        // tile has real variance, the ghost's rect captures featureless
        // bar. Without Screen Recording the standings rule stands in.
        for (id, first) in escapeFirstSeen
            where standing.contains(id) && lastReassert >= first
                && now.timeIntervalSince(first) > 8
                && !resistantConcealed.contains(id)
                && !pendingResistance.contains(id)
                && !pixelDisproven.contains(id) {
            if let item = concealedItems.first(where: {
                $0.bundleID == id && onRowIDs.contains($0.id)
            }), let rect = MenuBarTileMath.captureRect(
                of: item, row: rows.first { $0.intersects(item.bounds) } ?? rows[0]) {
                pendingResistance.insert(id)
                let lastReassert = self.lastReassert
                Task { [weak self] in
                    guard let self else { return }
                    defer { self.pendingResistance.remove(id) }
                    guard let image = await self.captureEscapee(rect) else {
                        // No Screen Recording — the standings rule.
                        self.noteEscapeStanding(id, lastReassert: lastReassert)
                        return
                    }
                    if Self.tileHasPixels(image) {
                        if self.resistantConcealed.insert(id).inserted {
                            MenuBarAssessmentBackend.log.notice("resistant: \(id, privacy: .public) — pixels prove the escape; covering")
                        }
                    } else {
                        // A flat capture is the ghost — not an escapee,
                        // and the standings rule must not promote it.
                        self.pixelDisproven.insert(id)
                    }
                }
            } else {
                noteEscapeStanding(id, lastReassert: lastReassert)
            }
        }
        // `lastReassert` is also the standings clock: it must keep
        // advancing while unresolved escapees stand, or a lone stubborn
        // escapee collects one stamp and the three-stamp proof never
        // completes. The ≥20 s cadence matches `recordEscapeStanding`'s
        // spacing — each sweep is one stamp, and the re-assert itself is
        // the retry the standing item exists to provoke.
        let unresolved = standing.subtracting(resistantConcealed).subtracting(pixelDisproven)
        let sweepDue = !unresolved.isEmpty && now.timeIntervalSince(lastReassert) >= 20
        guard (!escaped.isEmpty && !throttled) || sweepDue else { return }
        lastReassert = now
        MenuBarAssessmentBackend.log.notice("reassert: \(escaped.sorted().joined(separator: ", "), privacy: .public) standing while concealed")
        concealer.reassert()
    }

    /// The no-permission proof: an escapee that stands through three
    /// re-asserts, each ≥20 s after the last, earns the cover the
    /// pixel test would have settled in one. `resistant:` logs only
    /// when the state actually fires.
    private func noteEscapeStanding(_ id: String, lastReassert: Date) {
        escapeStandings[id] = Self.recordEscapeStanding(
            stamps: escapeStandings[id] ?? [], lastReassert: lastReassert)
        if (escapeStandings[id]?.count ?? 0) >= 3,
           resistantConcealed.insert(id).inserted {
            MenuBarAssessmentBackend.log.notice("resistant: \(id, privacy: .public) stood through three re-asserts — covering")
        }
    }

    /// One more standing on a re-assert's stamp — a new stamp per
    /// re-assert, ≥20 s apart, so a still-standing item accumulates
    /// exactly one per sweep. Pure so the test pins the cadence.
    nonisolated static func recordEscapeStanding(stamps: [Date], lastReassert: Date) -> [Date] {
        guard lastReassert > .distantPast, stamps.last != lastReassert,
              stamps.last.map({ lastReassert.timeIntervalSince($0) >= 20 }) ?? true
        else { return stamps }
        return stamps + [lastReassert]
    }

    /// Capture the rect an escapee reports — the same path the Item
    /// Bar's tiles take (the display filter excludes our windows, so
    /// what lands is the item, not a cover). nil means capture is
    /// unavailable — no Screen Recording grant.
    private func captureEscapee(_ rect: CGRect) async -> CGImage? {
        if let escapeeCapture { return await escapeeCapture(rect) }
        if escapeeCaptureSource == nil { escapeeCaptureSource = DisplayFilterSource() }
        return await escapeeCaptureSource?.capture(rect)
    }

    /// Whether a captured tile proves the item draws pixels — a live
    /// escapee's glyph spreads luma widely over the bar's material;
    /// the Accessibility ghost's rect captures a featureless strip.
    nonisolated static func tileHasPixels(_ image: CGImage?) -> Bool {
        guard let image else { return false }
        let width = 16, height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var lumas: [Double] = []
        lumas.reserveCapacity(width * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            lumas.append(0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1])
                         + 0.0722 * Double(pixels[i + 2]))
        }
        let mean = lumas.reduce(0, +) / Double(lumas.count)
        let variance = lumas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lumas.count)
        // A real item's glyph deviates hard from the flat material —
        // a std dev over ~20 luma points; uniform bar reads ~0.
        return variance > 400
    }

    /// One pass of ghost triage over a concealed app's items. An item
    /// proves live only by moving to an on-row frame it never reported
    /// while concealed — a novel slot is a registration the assertion
    /// did not adopt. A frozen frame, an off-row report, or a return
    /// to a slot the ghost already showed is still the Accessibility
    /// ghost the agent leaves behind: pressable, undrawn, harmless.
    /// Proof is NOT sticky — an item un-proves when its frame returns
    /// to a ghost slot, or when ten seconds pass without a novel slot
    /// (a still-standing "escapee" is the ghost relayouted, and a live
    /// item that keeps moving re-proves on its own). Pure so the test
    /// pins the table.
    /// `retain` holds item ids with a classification in flight — the
    /// standings proof needs ~60 s to accumulate, so the 10 s decay must
    /// not pull the ground out from under it. A ghost-frame return still
    /// un-proves regardless.
    nonisolated static let proofSeconds: TimeInterval = 10

    nonisolated static func concealedEscapees(
        onRow: Set<String>, frames: [String: CGRect], previous: [String: CGRect],
        ghostHistory: [String: Set<CGRect>], proven: [String: Date], now: Date,
        retain: Set<String> = []
    ) -> (proven: [String: Date], ghostHistory: [String: Set<CGRect>]) {
        var proven = proven
        var history = ghostHistory
        for id in onRow {
            guard let frame = frames[id] else { continue }
            let seen = history[id] ?? []
            if let stamp = proven[id] {
                if seen.contains(frame)
                    || (now.timeIntervalSince(stamp) > proofSeconds && !retain.contains(id)) {
                    proven[id] = nil
                } else {
                    continue
                }
            }
            let moved = previous[id].map { $0 != frame } ?? false
            if moved && !seen.contains(frame) {
                proven[id] = now
            } else {
                history[id, default: []].insert(frame)
            }
        }
        // Decay applies off-row too — a proven item that left the row
        // ten seconds ago is the ghost again, unless its classification
        // is still being settled.
        for (id, stamp) in proven
            where now.timeIntervalSince(stamp) > proofSeconds && !retain.contains(id) {
            proven[id] = nil
        }
        return (proven, history)
    }

    /// Whether a listed item is a concealed app's Accessibility ghost —
    /// a node still reporting the frame it froze at while the agent
    /// owns its pixels. Only an item that proved live by moving may
    /// speak for its bundle; the ghost must not write sections, learn
    /// drags or earn covers.
    func isConcealedGhost(_ item: MenuBarItem) -> Bool {
        guard let id = item.bundleID,
              let section = liveSettings().concealedApps[id], section != .shown
        else { return false }
        return liveConcealedItems[item.id] == nil
    }

    func concealedPlan(from listing: MenuBarHidePlan) -> MenuBarHidePlan {
        let all = listing.shown + listing.hidden + listing.alwaysHidden
        var seen: [String: [MenuBarItem]] = [:]
        for item in all {
            guard let id = item.bundleID else { continue }
            seen[id, default: []].append(item)
        }
        for (id, items) in seen { knownItems[id] = items }
        // Ghost eviction: an app that quit takes its remembered bounds
        // with it — stale frames must not feed the plan, the covers, or
        // the card forever.
        let running = runningApps.snapshot()
        for id in knownItems.keys where seen[id] == nil && !running.contains(id) {
            knownItems[id] = nil
        }
        // The live maps — the curated ones with any overlay laid over.
        let live = liveSettings()
        let apps = live.concealedApps
        // The positional map, read only for items the agent cannot
        // target (no bundle identifier) — see the cover-fallback below.
        let sections = live.sections
        var plan = MenuBarHidePlan()
        // Standing means on ANY display's bar — a secondary-screen item
        // is visible exactly like a main-row one.
        let rows = MenuBarItemLister.menuBarRows()
        let onRow: (CGRect) -> Bool = { bounds in rows.contains { $0.intersects(bounds) } }
        plan.shown = all.filter { item in
            // Positional overrides win for anything the agent cannot
            // take (Apple extras, bare helpers) — the cover-fallback
            // below draws them.
            if let override = sections[item.id], override != .shown { return false }
            guard let id = item.bundleID, let section = apps[id] else { return true }
            return section == .shown
        }.filter { onRow($0.bounds) || MenuBarItemLister.isProtected($0) }
        // The Item Bar mirrors the row's order: each app's last known
        // on-row x — the remembered items' frames where they are on the
        // row, plus every ghost slot history reported — and bundle IDs
        // nobody ever saw placed sort after, by name.
        var lastX: [String: CGFloat] = [:]
        for (id, items) in knownItems {
            for item in items where onRow(item.bounds) {
                lastX[id] = min(lastX[id] ?? .infinity, item.bounds.minX)
            }
        }
        for item in all {
            guard let id = item.bundleID,
                  let ghosts = concealedGhostFrames[item.id] else { continue }
            for ghost in ghosts where onRow(ghost) {
                lastX[id] = min(lastX[id] ?? .infinity, ghost.minX)
            }
        }
        for (id, section) in Self.concealedOrder(apps: apps, lastX: lastX) {
            let items = knownItems[id] ?? []
            switch section {
            case .hidden: plan.hidden.append(contentsOf: items)
            case .alwaysHidden: plan.alwaysHidden.append(contentsOf: items)
            case .shown: break
            }
        }
        // macOS parks overflow items nobody mapped — same semantic as
        // the hider's own plan: parked is hidden, it just isn't ours.
        // Without them the card's list and the Item Bar go blind to
        // half of what is actually off the row.
        let accounted = Set(plan.shown.map(\.id) + plan.hidden.map(\.id)
                            + plan.alwaysHidden.map(\.id))
        for item in all where !accounted.contains(item.id)
            && !MenuBarItemLister.isProtected(item) && !item.isNativeOverflowControl {
            // Positional picks under the concealer (Apple extras, bare
            // helpers): Auto stays where the row puts it — which is the
            // shown run it was already filtered out of, so only Honest
            // hidden assignments land here.
            switch sections[item.id] {
            case .some(.alwaysHidden): plan.alwaysHidden.append(item)
            case .some(.shown): break
            default: plan.hidden.append(item)
            }
        }
        // Cover-fallback, Ice-style: a hidden item still standing on
        // the row — one the agent cannot or will not take (Apple
        // extras, bare helpers, unattributed scene items) — gets a
        // cover where it sits. Remembered items are NOT cover
        // candidates: `knownItems` bounds are where the item last stood
        // before the agent removed it, so covering them paints empty
        // bar — and whatever lives there now, ears included (the tinted
        // "blue block" and the paved-over wings this once caused).
        // Agent-concealed items are not candidates either: the agent
        // owns their hiding, and a concealed item leaves the
        // Accessibility tree or reports the frame it last stood at — a
        // ghost that intersects the row. Covering the ghost paved the
        // stretch the *shown* run reflowed into.
        let listedIDs = Set(all.map(\.id))
        let concealed = MenuBarConcealPlan.concealed(apps: apps, revealed: hider.revealed)
        let agentOwned = { (item: MenuBarItem) in
            // Resistant escapees proven standing through a re-assert
            // are agent-proof: covers paint over them like the other
            // items the agent cannot take — except mid-reveal, when
            // the row is supposed to show what it hides.
            item.bundleID.map {
                concealed.contains($0)
                    && !(self.resistantConcealed.contains($0) && self.hider.revealed.isEmpty)
            } ?? false
        }
        var coverHidden: [MenuBarItem] = []
        var coverAlways: [MenuBarItem] = []
        for item in plan.hidden where listedIDs.contains(item.id)
            && onRow(item.bounds) && !agentOwned(item) { coverHidden.append(item) }
        for item in plan.alwaysHidden where listedIDs.contains(item.id)
            && onRow(item.bounds) && !agentOwned(item) { coverAlways.append(item) }
        var blockers = plan.shown.map(\.bounds)
        if let boundary = host?.boundaryFrame { blockers.append(boundary) }
        // The island (notch plus shoulders — the ears' home) and the
        // icon's mirror (its ‹ included) are ours: a merged run must
        // break at them or the cover paves a surface it shares the
        // window level with. Their frames are AppKit's beside
        // the items' Quartz ones — `coverRuns` reads only x, which the
        // two spaces share.
        if let island = ScreenBarGeometry.islandScreenRect { blockers.append(island) }
        // The mirror's frame from before this pass seats it: a seat
        // that then moves re-plans the covers (`recutCovers`).
        if let mirror = standingMirrorFrame { blockers.append(mirror) }
        plan.hiddenCovers = MenuBarItemHider.coverRuns(covered: coverHidden, blockers: blockers)
        plan.alwaysHiddenCovers = MenuBarItemHider.coverRuns(covered: coverAlways, blockers: blockers)
        return plan
    }

    /// The Item Bar's app order under the concealer: the system menu
    /// bar's own left-to-right. Apps with a remembered on-row x sort
    /// by it; apps never seen placed follow, bundle ID as tiebreak.
    /// Pure so the test pins the order.
    nonisolated static func concealedOrder(
        apps: [String: MenuBarItemSection],
        lastX: [String: CGFloat]
    ) -> [(id: String, section: MenuBarItemSection)] {
        apps.sorted { lhs, rhs in
            let lx = lastX[lhs.key] ?? .infinity
            let rx = lastX[rhs.key] ?? .infinity
            return lx == rx ? lhs.key < rhs.key : lx < rx
        }.map { ($0.key, $0.value) }
    }

    /// Nothing is concealed on its own: hiding starts only when the
    /// person picks a section — the card's picker, an Item Bar tile, the
    /// menu, the palette. Under the concealer position never writes one:
    /// the agent reorders the bar itself and a concealed item cannot be
    /// ⌘-dragged, so a drag or a reflow would only ever teach noise.
    /// The marker stays for file compatibility — old files that carry
    /// an auto-seeded map are cleared by `migrateSectionsIfNeeded`.
    func seedConcealedAppsIfNeeded(from listing: MenuBarHidePlan) -> Bool {
        guard !settings().concealSeeded else { return true }
        // A fresh install whose own icon is parked at the first scan
        // must not block the engine forever: past `adoptionTimeout` the
        // path just marks the map seeded; nothing is inferred from the
        // listing.
        let ownPresent = listing.shown.contains { !Self.isForeignOwner($0.ownerName) }
        guard ownPresent
                || Date().timeIntervalSince(concealerStartedAt) >= Self.adoptionTimeout
        else { return false }
        update { draft in draft.concealSeeded = true }
        return true
    }

    /// Hand the concealer its target for the current reveal state.
    func syncConcealer() {
        guard let concealer else { return }
        // Nothing of ours grows under the agent — whatever the spacer
        // engine wrote on the seeding pass folds back.
        host?.setBoundarySpacer(0)
        // The icon follows the engine from its first pass, not from the
        // first assertion.
        updateIconMirror()
        // The first assertion waits out the grace: a relaunch's previous
        // assertion is still draining for a beat after the engine comes
        // up. Nothing else gates it — macOS never draws our own item
        // under our assertion, so there is no adoption to wait for.
        let inGrace = Date().timeIntervalSince(concealerStartedAt) < Self.adoptionGrace
        if prePhotographPending, !concealer.isConcealing {
            // The one moment every app about to be hidden is still drawn:
            // photograph them (and the shown ones) before the first
            // assertion takes their pixels.
            if !inGrace {
                prePhotographPending = false
            } else {
                let standing = onRowItems(in: listedItems)
                if !standing.isEmpty {
                    prePhotographPending = false
                    photograph(standing)
                }
            }
        }
        guard concealer.isConcealing || !inGrace else { return }
        let concealed = concealTarget()
        concealer.apply(concealed: concealed, running: runningApps.snapshot())
        clickBridge?.update(items: lastPlan.shown, concealing: !concealed.isEmpty)
    }

    private func concealerChanged() {
        clickBridge?.update(items: lastPlan.shown, concealing: concealer?.isConcealing ?? false)
        refreshBoundary()
        updateIconMirror()
        engineVersion += 1
        // An assertion refused or recovered: the ear's alert follows at
        // once, not on the next plan pass.
        refreshEarFeed()
    }

    // MARK: The glyph camera

    /// The menu bar's appearance — the icon's, which follows the
    /// wallpaper under the bar, not the app's.
    func barIsDark() -> Bool {
        let appearance = host?.face.appearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The items among `items` that stand on a bar and are someone
    /// else's to photograph — never ours, never the protected system
    /// items, and never an app the live assertion conceals right now
    /// (its frame is a ghost that draws nothing). Before the first
    /// assertion, and for the apps a reveal or a lift narrowed out of
    /// it, the items are drawn.
    func onRowItems(in items: [MenuBarItem]) -> [MenuBarItem] {
        let rows = MenuBarItemLister.menuBarRows()
        let concealedNow = concealer?.concealedApps ?? []
        return items.filter {
            Self.photographable($0, among: items, rows: rows, concealed: concealedNow)
        }
    }

    /// Whether `item` can be photographed as itself: someone else's
    /// (never ours, never a protected system item, never the «), on a
    /// row, not concealed by the live assertion, and alone in its rect.
    /// A concealed app's ghost keeps reporting its old frame after the
    /// row repacks, so two listed items sharing a stretch of bar means
    /// one of them is a ghost over the other — and a photograph of that
    /// rect could file one app's glyph under the other's name. Pure so a
    /// test pins it.
    nonisolated static func photographable(_ item: MenuBarItem, among items: [MenuBarItem],
                                           rows: [CGRect], concealed: Set<String>) -> Bool {
        guard !hideAllTargets([item]).isEmpty,
              rows.contains(where: { $0.intersects(item.bounds) }),
              !(item.bundleID.map(concealed.contains) ?? false) else { return false }
        return !items.contains { other in
            other.id != item.id && other.bounds.intersection(item.bounds).width >= 4
        }
    }

    /// Drop every photograph more than a month old, whoever owns it — a
    /// glyph still in use is re-taken each launch before the first
    /// conceal, so only the forgotten ones reach the cap. Launch-time
    /// housekeeping, a beat after the camera is set; each photograph
    /// pass holds the same cap after that.
    func pruneGlyphs() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.glyphCamera?.cache.expire()
        }
    }

    /// The photographed glyph for an item in the bar's appearance — the
    /// card's layout editor wears the Item Bar's faces.
    func glyphFace(for item: MenuBarItem) -> MenuBarGlyphCache.Face? {
        glyphCamera?.cache.face(for: item, dark: barIsDark())
    }

    /// One photograph pass, off the caller's stack.
    func photograph(_ items: [MenuBarItem]) {
        guard let camera = glyphCamera, !items.isEmpty else { return }
        Task { [weak self] in
            let stored = await camera.photograph(items, rows: MenuBarItemLister.menuBarRows())
            if !stored.isEmpty { self?.bar.glyphsChanged(); self?.refreshEarFeed() }
        }
    }

    /// While a reveal holds the concealed apps on the row, photograph
    /// the stale ones once — after the fade-in, and only while nobody is
    /// using the row: the pointer off every surface the reveal serves
    /// and no listed item's menu open. Each frame lights the recording
    /// indicator and shifts the bar, which must never land under a
    /// pointer aiming at the items the reveal just brought back. The
    /// watch is a pointer read and a window list twice a second, for
    /// the life of one reveal, and stops once the pass is taken.
    func photographReveal() {
        guard concealer != nil, glyphCamera != nil, !hider.revealed.isEmpty else {
            revealPhotographed = false
            revealPhotoWatch?.cancel()
            revealPhotoWatch = nil
            return
        }
        guard !revealPhotographed, revealPhotoWatch == nil else { return }
        revealPhotoWatch = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                guard self.concealer != nil, !self.hider.revealed.isEmpty else {
                    // The reveal (or the engine) went first: the next
                    // one starts a watch of its own.
                    self.revealPhotoWatch = nil
                    return
                }
                if !self.reveal.pointerOnRevealSurface(), !self.listedItemMenuOpen() {
                    self.revealPhotographed = true
                    self.revealPhotoWatch = nil
                    let tucked = MenuBarConcealPlan.concealed(apps: self.curatedSettings().concealedApps,
                                                              revealed: [])
                    let standing = self.onRowItems(in: self.listedItems).filter {
                        $0.bundleID.map(tucked.contains) ?? false
                    }
                    self.photograph(standing)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}
