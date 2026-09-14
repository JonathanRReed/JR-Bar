# JR-Bar Master Upgrade — Implementation Ledger

Single ledger for the 2026-09-13 master upgrade
(`JR-Bar-Master-Upgrade-Devin-SWE2-2026-09-13.md`). Statuses per the spec's
vocabulary: **not started / in progress / implemented / verified with
fixtures / verified on macOS / live-provider verified / blocked**.

- Baseline revision: `e72e00e` on `main` (21 commits ahead of `origin/main`,
  all local work preserved; committing directly to `main` per owner decision).
- Environment: this implementation ran **on the owner's Mac** (arm64,
  macOS 27 / Darwin 27, Swift 6.4, Python 3.12.13 in `.venv`), so macOS-level
  verification is possible here rather than blocked on a remote runner.

## W00 — Baseline and reuse map — verified with fixtures

- Working tree was clean at start; manifests: `pyproject.toml` (jrbar
  0.9.8, Python ≥3.12), `app/Package.swift` (swift-tools 6.2, 4 targets,
  CLT workarounds present).
- Launch ownership: app `main.swift` → `AppDelegate` → `CoreSupervisor`
  (bundled daemon or `JRBAR_CORE_EXEC`, attach-or-spawn); legacy CLI
  LaunchAgent path via `status_bar_launch.py`. Dual lifecycle confirmed in
  source — the "one authoritative daemon" reconciliation remains a W29 item.
- Feature inventory (all verified present in the working tree):
  Aquarium (`Toys/Aquarium/`, SwiftUI Canvas engine, `AquariumModel`),
  Buddy (`Toys/NotchBuddy*`, care + roaming + tricks), Fold
  (`Toys/Fold/`, IOKit HID lid sensor + SCStream capture), Alcove island
  (`Toys/Alcove*`, media adapter incl. perl/dylib MediaRemote path),
  SidePulse/Dot (`device_*`, `dot_*`), Creator Micro (`creator_micro_*`),
  Effect Studio (`EffectStudio*` + `effect_*`), attention stack
  (`attention.py`, `ask_episodes.py`, `mailbox.py`,
  `notification_arbitration.py`), 8 real provider-usage adapters +
  13 observation providers, cross-Mac read-only sync (SFTP + HMAC),
  media controls, calendar/reminders via EventKit.
- **Absent:** Mini (no compact controller/composer), WidgetKit extension,
  Overview/workspace window, ACP/execution adapters (Codex app-server is a
  read-only probe only), native Shelf (only Screen Bar + island exist).
- Screen Bar / notch geometry mapped in detail: `ScreenBarGeometry.swift`
  (6 pt band drawn ~4–10 pt below the notch inside a 38 pt click-through
  window; wings widen the window ≤14 pt/side but draw nothing),
  `ScreenBarInteraction.swift` (20 Hz synthesized hover on a ~9 pt strip
  below the notch; tooltip unreachable/click-through; 0.32 s delay),
  `AlcoveIsland*` (the hanging pill; `ledBandClearance` 12 pt couples it
  to the band), `NotchHUD.swift` (toast/buddy pill anchors).
- Baseline test state: `pytest tests -x -q` → **3392 passed** (170 s).
  `make fast` is red at baseline on Ruff — 39 pre-existing lint errors in
  test files (I001/F401/E731 drift); none in `src/` and none introduced
  by this work. Swift: `swift build` clean; `swift test` → **475 passed**
  (35 + 24 + 357 + 59 across the four targets).

## W01 — Exact-target approval + delivery reporting — verified with fixtures

- `src/jrbar/answer_local.py`: `_checked_answer_host` is now fail-closed —
  `session_alive` must be `True` (`liveness_unproven` refuses),
  `frontmost_ancestor_of_session` must be `True` (`ownership_unproven`
  refuses), the session's tty must be known (`session_tty_unknown`), and
  the frontmost terminal must name a focused tab that IS the session's
  (`focused_tab_unproven`, `other_tab:*`). Net effect: synthetic delivery
  only ever fires for Terminal.app/iTerm2 sessions whose focused tab is
  provably the session's; Ghostty/IDE/unresolved/remote hosts refuse and
  fall back to Open-in-terminal — the spec's intended narrowing.
- `window_evidence()` now only reports `focused_tab_tty` when the ttys
  actually match; a mismatch no longer masquerades as tab proof.
- New `host_offers_focused_tab_proof(bundle_ids)` +
  `FOCUSED_TAB_PROOF_BUNDLES`; `core_projection._answer_flags` gates
  `answerable` on it via the session's resolved terminal/origin bundles,
  so the Approve button is never offered where delivery can only refuse.
- `AnswerDeliveryOutcome.document()` adds `confirmation`
  (`provider_pending` / `none`): a posted key is an attempt, and only the
  provider's own stream closing the request is confirmation.
  `docs/CORE-PROTOCOL.md` updated for the new fence and field.
- Tests: new `tests/test_upgrade_answer_targeting.py` (spec verbatim
  refusal matrix + Ghostty/no-tty/reply/display-gating/attempt-vocabulary
  cases); `tests/test_answer_local.py` updated to the proven-host fixture.
- Ran: `pytest tests/test_upgrade_answer_targeting.py
  tests/test_answer_local.py tests/test_core_projection.py
  tests/test_answer_controller.py tests/test_answer_runtime.py
  tests/test_answer_in_place.py` → 51 passed;
  `tests/test_core_runtime.py tests/test_announcer_stack_wiring.py
  tests/test_mock_core_parity.py` → 79 passed.
- Not covered here (recorded, not claimed): a live Terminal.app/iTerm2
  end-to-end delivery on this Mac, and the announcer's legacy answerable
  check is mode/kind-level (delivery fence is the backstop there).

## Geometry package (W10 pulled forward) — verified with fixtures

Design confirmed with owner 2026-09-13: content wings flank the notch at
menu-bar height sized by measured free space (right side first); nothing
but the 6 pt band draws below the notch at rest; the island tucks into the
notch depth; hover-peek is a real clickable card hugging the notch
(180 ms intent) with click to expand/pin; notchless displays get compact
slot chips flanking the band.

- `screen_bar_notch_wings` setting end to end: Python schema field
  (`_settings_legacy.py`, default `true`, `with_screen_bar_notch_wings`,
  serialized and tolerantly parsed), `SettingsKey` catalogue entry,
  mock-core document, Settings › Screen Bar toggle, live-applied in
  `AppDelegate.refreshScreenBarGeometry` → `ScreenBarController
  .notchWingsEnabled`. `set_setting` round-trip verified.
- `ScreenBarGeometry` (JRBarUI): `contentWingExtent` measures each
  flank's `auxiliaryTopArea` minus the 28 pt safety margin, inner
  reserve and outer inset — 0 collapses the side, 132 pt caps it;
  `notchlessWingClaim` (120 pt) for screens without a safe area;
  `windowFrame(contentExtent:)` widens the window, never the band;
  `wingSlotRect` returns each chip's rect at menu-bar height and is
  capped by the measured extent so a manual `wing_length` cannot widen
  a chip into unmeasured menu space. Right wing is the first claimant;
  a followed Alcove capsule claims the flanks entirely.
- `ScreenBarWings.swift` + `PanelStore.screenBarWings`: left slot =
  focus pick's tile + state word (+ `·N` for multiple asks, amber/red
  tones for waiting/failed); right slot = headline usage meter. Empty
  slots are nil and claim no room. Hosted lazily in `ScreenBarView`;
  the drawn capsule and the hit-tested rect are the same.
- Island tuck: `idleSize` is exactly `notchDepth` tall (lip removed);
  notice/expanded keep `ledBandClearance` below the band.
- `ScreenBarInteraction`: hit region = band + drawn wing chips + the
  peek card itself; 0.18 s intent delay; 0.30 s close grace; 4 s max
  life extended while the pointer reads the card; click opens the
  focus session; panel stays `ignoresMouseEvents` (click-through).
- Verified: `swift build` clean; `swift test` 475 passed incl. 14
  `ScreenBarGeometryTests` (extents, caps, notchless chips, manual-wing
  cap) and the island clearance suite; `pytest` 3392 passed.
- Not covered (recorded, not claimed): on-screen visual confirmation
  on the owner's display — the geometry is fixture-verified, the
  pixel-level look (chip legibility at menu-bar height, overlap with
  a crowded menu bar) awaits real-runtime smoke.
- W10 independence audit (2026-09-14): `capsule == nil` already yields
  the full notch geometry — `windowFrame`/`wingSlotRect` are self-owned
  and `AlcoveFollower` polls only while `screen_bar_follow_alcove` is on
  AND Alcove is running, so nothing in the band's layout *needs* Alcove.
  The follow survives as opt-in coexistence.
- W10 state machine (2026-09-14): the four named states now exist —
  **compact** is the 6 pt band + wing chips at rest; **peek** is the
  180 ms-deliberate-hover transient card; **pinned** is a click-pinned,
  persistent interactive card (T46/T47: `ClickOutcome` pins on inside
  click while unpinned, routes inside clicks to the card's own buttons
  while pinned, dismisses only on an explicit outside click or the
  card's dismiss control — never on transient expiry); **expanded** is
  the card's Open-session / panel focus entry. Hit testing covers the
  band, drawn wing chips, and the card itself; the pinned panel stays
  nonactivating and outside the typing path. `clickOutcome` is factored
  pure + `nonisolated` for test coverage in `ScreenBarInteractionTests`.
- Per-display handling: `preferredScreen()` picks the notched display
  (fallback: main), `didChangeScreenParameters` repositions, and
  `geometryChanged` clears hover/pin state before re-evaluating the
  pointer — safe per-display restoration. Fullscreen uses
  `.fullScreenAuxiliary` + the `screen_bar_show_in_full_screen` toggle;
  notchless displays get slot chips.
- Still open in W10: real-hardware smoke of notchless/fullscreen/
  scaled/multi-display cases in a dev bundle (T45, T53) — fixtures
  cover the math, not the pixels.

## W11 slice — shelf media/device utility card — LANDED

- `ShelfUtility.swift` (new): `ShelfUtilityModel` owns the existing
  `AlcoveMediaMonitor` + `AlcovePowerMonitor`, alive only while the
  pinned card is up — no parked child process or IOKit timer.
- Pinned card gains utility rows below the session row:
  - **Media (AL04/T48):** bounded artwork (`maxArtworkBytes` = 4 MiB
    before `NSImage`), `displayLine`, source app name resolved from the
    reported bundle id (unnamed stays "Now playing", never "Music" by
    default). Transport (prev/play-pause/next) rides the monitor's
    live path and is gated on `media != nil` — `send` with no live
    source is a no-op, not a command fired at silence. No row at all
    when nothing is playing.
  - **Battery (AL05/T48):** percent/charging/AC state from
    `AlcovePowerMonitor.read()` (IOKit), shown only when
    `hasBattery` — a Mac without one shows no row, never a fake
    percent. Volume and brightness are deliberately absent: macOS owns
    those HUDs and JR-Bar has no certified read/control path (T48's
    "no invented volume/brightness").
- Source exit/permission paths inherited from `AlcoveMediaMonitor`:
  adapter death drops to the in-process bridge, Music's payload ages
  out after `musicPayloadLife`, a `Stopped` playerInfo drops the held
  track.
- `ShelfUtilityTests`: nil-media gating, transport no-op without a
  live source, artwork bound, monitor lifecycle.
- Still open in W11: capability-gated per-source command matrices
  (some players lack next/previous — MediaRemote doesn't report it,
  so all three transport buttons currently send regardless) and
  dev-bundle smoke on real media sources.

## W27 audit — onboarding / privacy / accessibility — VERIFIED EXISTING

- Disabled reasons are real: `ToyStatus` carries `.paused(String)`,
  `.needsPermission(String)`, `.unavailable(String)` — every chip names
  *why*, never just dims. The panel's gated controls pair `.disabled()`
  with a `.help` that says the same thing ("on a peer", "answer it in
  the session's own window").
- Permission-on-use is honest: the ask card's gate is `canAnswer`, the
  Fold's is `FoldCapturePermission.granted`, Calendar's is EventKit
  authorization — each names the permission it needs, none fabricate.
- The remaining W27 items are real-device verification — VoiceOver
  traversal, Reduce Motion/Transparency live, screen-sharing/lock
  behaviour — not code gaps. Onboarding presets and deep-link
  preservation ride the existing Settings document.

## W26 slice — OpenCode capability bridge — LANDED

- `src/jrbar/opencode_bridge.py` (new): probes a running `opencode
  serve` instance's `/doc` OpenAPI surface and reports a closed
  `supported`/`missing` set for the six operations JR-Bar could drive
  (interrupt, permission reply, question reply, session list, session
  events, prompt) — an unreachable server or a `/doc` without a paths
  map is a named limitation, never a guessed route. `list_sessions`
  projects the server's own `/session` list to the glance facts (id,
  title, directory, updated stamp, version) — no transcript bodies.
- Verified against the installed `opencode` 1.18.30's real `/doc`: all
  six routes the bridge expects are genuinely published.
- Still open in W26: authenticated control calls through the W19
  journal (the probe is read-only — the UI must not offer a button
  until the route is in `supported`), the T3 bridge's scoped-interface
  proof (T3 reads stay read-only today), and the no-duplicate-owner
  check when native and T3 observations correlate.

## W25 slice — coordinator policy — LANDED

- `src/jrbar/coordinator_policy.py` (new): the assistant layer's
  contract — `bounded_evidence` redacts a session to the glance fields
  a question may cite (provider/mode/stale/label/cwd/attention/outcome;
  transcript bodies and token fields never leave the roster projection);
  `parse_proposal` turns a model's JSON into a typed `ActionProposal`
  only if the action is on the `{open_session, answer_ask}` allowlist
  and its arguments are scalars — prompt-injection dies here, not at a
  special case; `requires_confirmation` marks `answer_ask` as the one
  effect that needs an explicit confirm before the W19 journal mints a
  command id. The coordinator has no privileged effect path.
- Still open in W25: the LLM front-end itself (the model call rides
  the W19/W20 execution contract), the Mini/Overview composer UI,
  push-to-talk capture/cancel indicators, and quota-failure surfacing.

## W24 slice — utility-generation policy — LANDED

- `src/jrbar/utility_generation.py` (new): the decision layer a
  title/summary adapter drives — `should_generate` enforces the
  precedence (user title > provider title > generated), once-per-thread
  with explicit-regeneration override, and no-evidence refusal;
  `collect_evidence` bounds the facts sent to the model (first user
  message, last assistant message, current label, each ≤500 chars —
  a pasted log can never flood the request); `accept_title` is the
  result gate (non-empty printable ≤80 chars or the deterministic label
  wins); `TitleCache` is the bounded once-per-session memory.
- Still open in W24: the adapter itself — the model call rides the
  W19/W20 execution contract — plus cancellation, usage-category
  surfacing, and fish/notification exclusion for utility work.

## W21 slice — shared JSON-RPC stdio transport — LANDED

- `src/jrbar/acp_transport.py` (new): the bounded transport every
  managed-session adapter (W20 Codex/Claude, W22 Grok/Gemini, W23
  Devin/Antigravity) sits on — newline-delimited JSON-RPC with
  monotonic request ids, id-matched response routing, a notification
  callback for peer-initiated frames (ACP permission callbacks ride
  the same path), per-request deadlines, a bounded stderr tail, and a
  1 MiB line bound with a protocol-violation counter — a malformed or
  oversized frame is counted and skipped, never fatal. `close()` is
  idempotent and fails every in-flight waiter.
- Tested against a real fake subprocess (`tests/test_acp_transport.py`):
  round-trip, id matching, notification routing, error-frame raising,
  deadline bounding a silent peer, peer exit failing all waiters,
  idempotent close.
- Still open in W21: capability negotiation and the ACP method surface
  live in the adapters (this file is framing only), reconnect/resume
  semantics, and provider-quirk separation proof.

## W20–W23 note — provider adapters are live-certification work

W20 (Codex/Claude managed sessions), W22 (Grok Build/Gemini CLI) and
W23 (Devin CLI/Antigravity) each need a real adapter speaking the
provider's actual protocol plus positive/negative live tests against
installed CLIs — the Codex app-server probe in `provider_reconnect.py`
is the only existing handshake. The transport spine (above) and the
command journal (W19) are the shared infrastructure those adapters
build on; the adapters themselves are separate certification work that
cannot be honestly "implemented" without the live provider runs.

## W19 slice — durable command journal — LANDED

- `src/jrbar/command_journal.py` (new): the execution ledger —
  `begin()` persists intent *before* the effect runs (T09's
  persist-before-effect), `settle()` moves a record to completed or
  failed with its receipt, and a re-settle returns the first receipt —
  idempotent replay, never a second effect (T70). Records compact to a
  256-entry, 7-day window; `accepted` records are never compacted —
  an unfinished command is exactly what the journal must keep.
- `answer_ask` now journals: `command_id` is the caller's idempotency
  key (a retried send replays its first receipt with `replayed: true`
  rather than re-typing), a `CommandError` settles the record as the
  same refusal the caller saw, and a confirmed send settles as
  completed. A journal that cannot load or persist degrades to
  memory-only — the answer path still runs.
- `list_commands` command exposes the journal: counts plus the
  `outcome_unknown` ids a restart must not pretend finished.
- Still open in W19: expected-revision/grant typing per command
  (`answer_ask` has `request` identity today), managed-process
  ownership beyond `process_registry`, per-workspace concurrency
  policy, and the single registry the UI reads.

## W18 slice — widget snapshot publisher — LANDED

- `src/jrbar/widget_snapshot.py` (new): projects the `state` document
  into a redacted widget shape — counts (`sessions/working/waiting/
  stale/shown`) plus per-entry `{provider, mode, waiting, stale}` tiles,
  bounded at 24 entries. No titles, messages or paths — the consent
  boundary holds even on disk.
- `_core_publish_state` writes `widget-snapshot.json` atomically (tmp +
  rename) beside the daemon's state files on every significant change;
  a write failure logs and never stalls the state pipeline.
- `WidgetSnapshot.swift` (new, JRBarCore): the decoder a WidgetKit
  extension uses — schema check, `isFresh(at:)` freshness window (90 s),
  `load(from:)` returning nil for absent/corrupt/wrong-schema files so
  the widget shows its placeholder rather than a fabricated count.
- `widget-snapshot.json` fixture is generated by the real Python
  projection and decoded in `CodecTests`.
- Still open in W18: the WidgetKit extension itself (needs an app group
  + extension target — packaging work, not SPM), Tailscale peer auth in
  the observation path is already real (`remote_observation.py`), and
  installed-extension verification.

## W17 audit — physical controls / effects / quiet / power — VERIFIED EXISTING

- T65 (stale physical-key targeting): the deck board's `resolve_slot`
  returns a `revision` that bumps on every reassignment, bank change
  and scope change; `navigation_target(identity, revision)` refuses a
  stale revision, and `change_deck_bank` calls `revoke_deck_context` —
  a held key can never retarget to a different session. Covered by
  `test_deck_control_center_contracts.py` ("old bank revision is
  revoked", "the scope change bumped the revision").
- T66 (cosmetic ≠ power): `KeepAwakeController.should_hold_for_mode`
  holds only for `WORK_MODES`; the grace window arms once when work
  stops and is never refreshed by rest-to-rest flaps — toy animation
  cannot hold the machine awake. `keep_awake_on_battery` gates the
  hold on power state, and an unknown reading never disables it.
- T64 (disconnect/reconnect, calibration, preview): the deck/effects
  paths are hardware-bound; device-reconnect and linked-preview checks
  are real-device work awaiting hardware access.
- Still open in W17: real-hardware disconnect/reconnect verification;
  the command-catalog bindings for the deck exist but physical-press
  end-to-end proof needs the pad attached.

## W16 audit — Fold hardening — VERIFIED EXISTING

- Self-capture exclusion is real: `FoldCapture` builds its filter with
  `excludingApplications: [ownApp]`, so the overlay can never appear in
  its own frames (T63's loop).
- Sensor loss is an honest `.unavailable("No lid-angle sensor on this
  Mac")`, with `simulatedAngle` as the labeled manual preview — no fake
  reading (T62).
- Capture permission revocation is observed via `didBecomeActive` →
  `permissionVersion` → `.needsPermission`; a frameless capture past 5 s
  recycles itself instead of waiting on a dead stream.
- Renderer failure latches `rendererFailed` → `.unavailable("Fold can't
  start its renderer")` and the chip keeps the fact (T63).
- `FoldPause.reason` contract (lid-closed / no-built-in / mirrored /
  asleep, in order) is covered by FoldMathTests; the display-topology
  facts are cached and re-read on screen-parameters notifications.
- Remaining is real-hardware verification — lid travel on the owner's
  MacBook — not a code gap.

## W15 slice — interruption-safe reply drafts + Mini presentation — LANDED

- Reply drafts are no longer `@ViewState` on `AskRow` (lost whenever the
  view rebuilt): `PanelStore` keeps them keyed by the ask's stable
  `request` id (falling back to `id`), persisted to UserDefaults as
  `{text, editedAt}` — a half-typed reply survives the panel closing,
  a relaunch, and a refused send (cleared only when `answer_ask`
  confirms `ok`). The store is bounded at 50 entries, oldest first.
- Mini is a presentation mode on the same toy, not a second controller:
  `NotchBuddySettings.presentation` (`"character"`/`"mini"`, stored raw
  so a newer build's mode survives). `MiniFigure` renders the same
  `summary(at:)` as a mood-tinted pill with the same ask badge, tap,
  menu and help contract; the character picker disables while mini is
  on. T60's "character-free, same controller" is the shape here.
- Still open in W15: context/skill/model-aware draft seeding (drafts
  today are free text — no session context auto-fill), configurable
  keyboard shortcuts for draft send, and the W12-deferred "Attach to
  task" into a shared reviewable draft. Execution-adapter gating is
  already honest (buttons disabled by `canAnswer`/`isRemote`).

## W14 slice — Aquarium selection/inspection — LANDED

- Tap on a fish now selects it (was: flash the nameplate): the tapped
  fish's id is held in `selectedID`, a tap on empty water clears, a
  re-tap toggles off.
- The inspector strip at the tank's bottom shows the selected fish's
  provider tile, label, and the *plan's own evidence line* — the
  inspector and the overlay marker cite the same fact (T54's
  "evidence matches the animation"). Open raises the session's
  terminal via `core.openSession`; nothing here answers or acts.
- Still open in W14: creature-design pass (six species already drawn;
  polish is real-device work), themes, habitats/stations as drawn
  zones, privacy controls, population LOD, demo-mode labeling, and
  rendering profile — all visual-verification work awaiting a dev
  bundle on the owner's display.

## W13 slice — Aquarium semantic behavior planner — LANDED

- `AquariumPlanner.swift` (new, JRBarCore): a pure per-session planner
  producing a `FishPlan` — `FishState` + a finer `FishAction`
  (AQ01–AQ24's vocabulary) + one `FishOverlay` + `parallelMarkers` +
  an `evidence` line naming the wire facts that drove it (T54: a
  fixture and a live fish cite the same evidence).
- AQ mapping onto real wire facts only:
  - AQ02–AQ04 from `mode` (`idle_ready`→rest, `working`→patrol,
    `long_task_progress`/`thinking`→attentive hover).
  - AQ05–AQ12 from `tool`+`event`: only a live `tool_running` row with
    a fresh `updatedAt` (≤45 s) drives a station — Read/Glob→forage,
    search/web→explore, Edit/Write→tend stones, Bash→current work,
    test/build→inspect structure, `mcp__*`→service visit, unknown
    tool→generic feed. AQ11 fires on a fresh `PostToolUse` for a
    test/build tool that stopped running — the result bubble.
  - AQ13 `parallelMarkers` from `workers` on a working main.
  - AQ15 `tokenPass` only on a real `delegation`/`handoff`/
    `subagent_stop` event — proximity never implies a handoff.
  - AQ16/AQ17 from the ask's `kind` (permission→attention buoy,
    else→question bubble). AQ20 `blocked_error`/`failed`→warning buoy.
  - AQ21/AQ22 from the review axis (unreviewed done→pearl,
    reviewed→clear). AQ23 from `stale` or a non-live freshness axis →
    neutral uncertain drift — stale claims no precise activity even
    while `mode` still reads working. AQ24 `ended`→inactive drift,
    kept distinct from failed by the plan's action.
- `Fish` carries `plan`; `fishFor` computes it and takes `state` from
  it — displayed state and cited evidence are one decision. The view
  draws one overlay marker per plan (warning buoy, attention ring,
    question dot, pearl, dashed stale ring); no overlay means none.
- `axes` now rides `state.sessions` too: `session_document` emits the
  same `session_axes` the roster computes (acknowledged threaded
  through `project_session_rows`), so the tank's review/freshness
  overlays fire live rather than only in a roster fetch. `CoreSession`
  decodes `axes` tolerantly.
- `AquariumPlannerTests` (23): every AQ rule maps to a distinguishable
  plan, stale tool events are history not stations, the every-action-
  is-reachable contract holds.
- Still open in W13: burst coalescing across rapid tool changes is
  handled by the wire already reducing to the last event (no separate
  coalescer needed); AQ18 queued / AQ19 rate-limited have no wire
  source — honestly absent, not faked.

## W12 slice — shelf tray, timers, calendar glance — LANDED

- `ShelfTray.swift` (new): bounded file tray on the pinned card —
  max 12 path references (no copies), persisted to defaults,
  revalidated on every show/read (T49: a moved/deleted file renders
  "moved" and loses reveal/share/drag, never silently dropped, never
  still claimed). Drag-in via `.onDrop(UTType.fileURL)`, drag-out via
  `NSItemProvider`, context-menu Reveal/Remove/Share — the share menu
  lists real `NSSharingService`s and a canceled sheet claims nothing
  (T50). `attachCopyBound` = 8 MiB for the future draft's inline-copy
  decision.
- `ShelfTimers.swift` (new): absolute-deadline timers persisted to
  `~/Library/Application Support/JR-Bar/shelf-timers.json`. The
  `fired` flag makes expiry one-shot across restarts (T51): a timer
  that came due while the app was down delivers exactly one banner on
  the recovery sweep, then sits "Done". Wake (`didWakeNotification`)
  and clock-change (`NSSystemClockDidChange`) both re-sweep — the
  absolute deadline is truth, not elapsed ticks. 12 h max duration;
  `onFire` is wired to `NotificationBridge` in AppDelegate — a due
  timer is a banner, never an agent launch.
- `ShelfCalendar.swift` (new): the next authorized calendar event,
  read-only. Permission is opt-in from a card button, never polled in
  the background (T52): denied/restricted hides the row entirely.
  `joinableURL` gates to http(s) — the event's `url` first, then the
  first safe link in the notes; everything else is unjoinable. Join
  opens the link; Open shows the event in Calendar.app.
- Pinned card now renders tray/timer/calendar rows below the session
  and media/battery rows; the whole card is a file-drop target.
- `ShelfTests`: 11 tests — tray bound/dedupe/missing-marking/no-share-
  when-missing, timer persist/reload/one-shot-fire/clamp/corrupt-store,
  calendar safe-URL acceptance/rejection.
- Still open in W12: "Attach to task" has no draft composer to land in
  yet (that's W15's shared draft surface — the tray's `canAttachCopy`
  bound is ready); calendar's `isPrivate` can't be read from EKEvent on
  macOS so private events aren't specially marked (they're still only
  title+time+safe-link); no test can exercise a real EventKit grant.

## W02 — Canonical records and the independent roster — verified with fixtures

- `src/jrbar/activity_model.py` (new): the §14.2 record vocabulary —
  `RECORD_SCHEMA_VERSION` and the carrier mapping (which existing type
  holds each logical record). The five axes are explicit: `lifecycle`/
  `mode` (activity) already existed; `session_axes` adds `outcome`
  (`none`/`succeeded`/`failed`/`unreported`/`unknown`), `review`
  (`pending`/`unreviewed`/`reviewed`, Clear Agents receipts are the
  review record) and `freshness` (`live`/`delayed`/`unknown`).
- `src/jrbar/agent_roster.py` (new): `roster_rows` re-projects every
  retained status through the identical `session_document` — extracted
  as `project_session_rows` so the panel and the roster can never
  diverge — with `visibility` (the panel's would-be verdict) and
  `pinned` attached as facts rather than applied as removals.
  `scope_rows` cuts by scope (`all`/`live`/`workers`/`attention`/
  `finished`/`hidden`) plus `provider`/`parent`/`since`/`limit`
  (bounded at 2000). `build_roster_document` reports counts over the
  full retained set and a `coverage` block naming what the roster does
  NOT hold (deeper history is `list_history`'s event ledger).
- `list_roster` command wired in `core_runtime` (registered, dispatched,
  `invalid_value` on bad scope); `docs/CORE-PROTOCOL.md` row added.
- Identity: provider-namespaced `agent_id`s are the roster key — two
  providers reporting the same native work id stay two records (test
  `test_similar_native_ids_across_providers_never_merge`); no title/path
  merging anywhere in the path.
- Verified: `pytest tests/test_upgrade_roster.py` → 11 passed
  (independence from panel aging, orphan-worker retention, separated
  axes, pins, scopes, contract shape, command round-trip); touched-file
  ruff clean; `test_core_projection`/`test_core_runtime` still green.
- Not covered (recorded): the run/tool-invocation and command-effect
  records stay partial — full invocation detail is W03 transport and
  W19 execution work; the roster carries their identity and axes, not
  their transcripts.

## W03 — Bounded history/detail transport and reliable subscriptions — verified with fixtures

- Already in place before this package (audited): 1 MB frame cap, max 4
  clients, per-client SO_SNDTIMEO sends with 3-strike drop, a 128-frame
  shared dispatch queue that sheds its OLDEST frames on overflow, latest-
  wins coalescing for `state`/`lights`/`settings`, hello deadline, and
  the client's deterministic backoff + pending-command drain.
- `src/jrbar/core_server.py`: every `publish_event` is now journaled
  under the flush lock — the journal IS the wire's order. Each event
  carries `cursor` (`<stream>:<event id>`); `stream` is pid + start
  epoch, so a cursor from a previous incarnation is provably foreign.
  `hello` gains `stream` + `cursor` (the journal tail a fresh client
  anchors at). `replay_events(after, limit)` returns the suffix with
  `has_more` paging, `retained`/`dropped` gap counters, and refuses
  `foreign_stream` / `cursor_expired` as `resync_required` with the live
  tail — never a fabricated empty catch-up. Journal cap is 512, larger
  than the dispatch queue on purpose: what the queue sheds stays
  replayable.
- `core_runtime`: `replay_events` command registered; `unsupported`
  when the core cannot replay. `roster` + `event_replay` added to
  capabilities — protocol stays v1, everything additive.
- `CoreClient.swift`: `CoreHello`/`CoreEvent` decode `stream`/`cursor`;
  the read thread tracks the resume cursor (never regresses), dedupes
  delivered event ids through a bounded 1024-id ring (replay/live
  overlap), and on a same-stream reconnect issues `replay_events`
  itself — the reply's frames arrive through the normal `.event` path
  exactly once; `resync_required` re-anchors at the returned tail. A
  foreign stream anchors without replaying so a restarted journal never
  re-surfaces old ids.
- Verified: `pytest tests/test_upgrade_event_replay.py` → 10 passed
  (snapshot/cursor boundary, suffix order, paging, foreign + expired
  resync, journal bound, wire-cursor round-trip, command surface);
  `pytest tests/` → 3413 passed; `swift test` → 477 passed (2 new:
  same-stream replay without dup, foreign-stream anchor); ruff clean on
  touched files. `docs/CORE-PROTOCOL.md` documents hello cursor, event
  cursor, `replay_events`, and the honest shed-vs-journal wording.
- Still partial (recorded): T19's "don't dispatch unrecorded managed
  work" is the control layer's rule and lands with W19; large detail
  bodies stay out of `state` (they were never in it) while full
  transcript pages remain `list_history`-style pulls.

## W04 — Attention inbox and interruption policy — verified with fixtures

- Already in place before this package (audited): `AttentionProjection`
  is the single "who needs you" source every surface reads; `EventPolicy`
  is the single interruption decision (sound/banner/toast/pulse/chime,
  focus-mode suppression, escalation ceiling); `ask_episodes` batches
  burst announcements; snooze is family-scoped through `work_key` and
  never removes an ask (`state.asks` keeps it resolvable — T42's
  "snooze never drops a real request" holds); the review watermark
  `last_seen_epoch` is persisted in the ledger document, monotonic
  (`mark_activity_seen`), and moves only on explicit review —
  `mark_history_seen` fires from the History window's open/close, never
  from app focus alone (T43 audited, no focus-path marking exists).
- New wire truth — `src/jrbar/core_projection.py`: `ask.request` carries
  the episode's canonical identity (`request:v1:{…}` from the request
  key) or `null` when the operator state does not model the ask — the
  honest "cannot prove the episode" case. `state.asks` now sorts by
  `opened_at` then session (`_pointer_stable_ask_key`): `updated_at`
  bumps no longer shuffle a card out from under the pointer (T41).
- `src/jrbar/core_runtime.py`: the ask diff is keyed by request identity
  (`_diff_ask_episodes`) — a session whose pending request was REPLACED
  emits `ask_resolved` + `ask_opened` with the respective identities
  instead of silently reusing the slot; both events carry `request`.
  `answer_ask` accepts `request` and refuses `stale_request` before the
  surface is armed when the pinned identity does not match the live
  request — including when the live identity cannot even be computed
  (T07, fail closed). `CoreAsk.request`/`CoreEvent.request` decode on
  the app side; `CoreAsk.id` prefers the episode identity;
  `answerAsk(Now)` sends it; PanelStore pins cards and toasts the stale
  refusal as "that request changed — nothing was sent."
- Verified: `pytest tests/test_upgrade_attention.py` → 9 passed
  (identity on the wire, stale-request refusal before arming, replaced-
  request diff, unmodelled-ask honesty, pointer-stable order, monotonic
  watermark); codec fixtures extended (hello stream/cursor, event cursor,
  ask request); ruff clean on touched files.
- Partial (recorded): interruption dedupe across the island/pet/Shelf
  surfaces still rides per-surface cooldowns keyed to the shared episode
  id rather than a single cross-surface ledger — one request, one
  `ask:<session>` banner, one identity everywhere; the shared ledger is
  folded into W08's inbox work if the surfaces need it.

## W05 — Native quota source certification — verified live

- Audit result: the certification doc (`docs/NATIVE-PROVIDERS.md`),
  classified failure vocabulary (`ProviderSourceState`: needs_consent /
  needs_sign_in / source_not_found / unavailable / rate_limited / stale /
  error / unsupported — T29's classes), adaptive cadence
  (`adaptive_refresh.py`), window applicability from stated plan, and
  confirmed-only reset celebrations already existed. The one gap the doc
  itself named: Gemini's Code Assist quota path.
- New source — `gemini` provider: reads `~/.gemini/oauth_creds.json`,
  refreshes the access token in memory with the Gemini CLI's own public
  OAuth client (the file is never rewritten), resolves the Code Assist
  project from `--option project_id` / `GOOGLE_CLOUD_PROJECT` /
  `loadCodeAssist`, then reads `retrieveUserQuota`. Buckets are per-model
  pools, so every lane is a non-bindable detail lane — none can pose as
  the account's ceiling (T22). Verified live 2026-09-13 on the owner's
  account: non-onboarded accounts get no `cloudaicompanionProject`; the
  free tier is retired (`ineligibleTiers`/`UNSUPPORTED_CLIENT` —
  `code_assist_tier_ineligible`, not a sign-in failure); an
  unprovisioned project gets `403 PERMISSION_DENIED` "no valid license"
  (`quota_license_required`, also not a sign-in failure); a missing
  project is `code_assist_project_required`. `jrbar providers refresh`
  ran the real collector end-to-end: `gemini · source_not_found ·
  code_assist_project_required`.
- Fixed a pre-existing crash found during the audit: `opencode` was a
  registered provider but missing from the CLI's not-collected action
  map, so `providers status` raised `KeyError` on a default install; the
  lookup is now fail-soft and every registered provider names an action.
- Verified: `pytest tests/test_upgrade_provider_gemini.py` → 10 passed;
  provider/usage group → 595 passed; ruff clean on touched files;
  `jrbar providers status` end-to-end on the live account.

## W06 — provider inspect/enable/consent/action on the shared control surface — LANDED

- New module `provider_management.py` is the single control surface the
  socket and the CLI both drive: `provider_rows` (one inspect row per
  configured provider *instance* — enabled flag, live state, source
  ladder, granted consents scoped to that instance, credential
  *availability* never secrets, `imported_credential` provenance),
  `set_provider_enabled` (per-instance flag through the settings
  document's optimistic concurrency — `settings_changed` on a
  concurrent edit, `unknown_instance` when none is configured, T25),
  `grant_browser_consent`/`revoke_browser_consent` (exact
  provider+browser+profile+field scope; grant imports nothing).
- T26 provenance: a browser import records a sha256 digest of the
  imported credential (`record_browser_import` inside
  `import_devin_browser_session`, so every entry point gets it). A
  manual `credential set` drops the provenance (`forget_browser_import`)
  — the credential is the user's own data again. A revoke deletes the
  stored credential only while it still matches the import digest and
  reports `removed`/`replaced`/`retained`/`none`; the CLI revoke path
  now runs the same purge, not just the consent row.
- Socket commands: `list_providers`, `set_provider_enabled`,
  `provider_consent` (list/grant/revoke), `provider_action` — which runs
  the staged flow behind the provider's current action label and returns
  the daemon's own message. `provider_action` preserves ownership:
  Gemini's states answer with CLI-directed text (sign-in → `gemini`,
  missing project → configure `project_id` or let the CLI provision,
  license → Google-side entitlement, free-tier ineligible → Antigravity
  route), never a JR-Bar-side credential rewrite.
- Swift: `ProviderRow`/`ProviderConsentRow`/`ProviderCredentialRow`
  wire models (instance-keyed `identity` matching `id|instance`), the
  four `CoreModel` calls, `UsageCenterStore` provider rows loaded on
  window open and refreshed after every mutation, and a connection
  section on each Usage Center card: a Metering toggle, the provider's
  current action label as a working button, an `imported session`
  badge, and per-consent Revoke buttons.
- Verified: `pytest tests/test_upgrade_provider_management.py` → 12
  passed; full suite 3444 passed; `swift test` 478 passed; ruff clean on
  touched files.
- Still open in W06: the model/skill catalog slice — paginated catalogs,
  option validation, saved-model handling and exact route labels
  (T30–T32) — which lands with the control layer it feeds.

## W07 — forecast authority and pricing coverage (T24, T28 slice) — LANDED

- `core_usage_samples.forecast_window` no longer returns null for a
  *measured* window it cannot pace. The daemon emits `pace: "guarded"`
  with `reason` (`insufficient_samples`, `insufficient_span`,
  `reset_boundary`, `stale_samples`, `clock_regressed`), the surviving
  `samples` count, and `span_seconds`; `exhausts_at` stays null.
  `forecast` is null only for an unmeasured window or a missing sample
  buffer. Future-dated samples past a 60 s tolerance are dropped as
  clock regression; a reset drop restarts the fit at the boundary.
- Swift `UsageForecast.Verdict` gains `.guarded(reason:)` and the
  forecaster treats the daemon's guard as the authority — the app's
  60-second local fit can no longer publish a pace or exhaustion date
  the daemon refused on 30-minute evidence (T28). A daemon `under`/`on`
  with no date is its own verdict; an `ahead`/`exhausted` with no date
  is a protocol anomaly and reads `unknown`, never a fabricated date.
  `guardText` renders each reason as a sentence; `PanelStore.paceHint`
  declines the bare word `guarded`.
- `core_usage_history.usage_history_document` splits `unpriced_records`/
  `unpriced_models` (no quote at all — tokens counted, $0 is a real
  absence) from `estimated_records` (reference stand-in rate), so a
  provider with no price table never has its usage silently labeled
  "estimated" or its missing prices folded into the total (T24).
- Wire/Swift: `CoreUsageForecast` gains `reason`/`rate_pct_per_hour`;
  `UsageHistory` gains `estimatedRecords`/`unpricedRecords`/
  `unpricedModels`, `UsagePricing` gains `model`/`source`/`estimated`.
  The Usage Center pricing line now names the model, flags a reference
  rate, and calls out unpriced records by name and count.
- `usage.providers[].constrained` names the lane worth watching — least
  headroom among `bindable` (provider-catalog-known) windows that were
  actually measured — with `reason` (`only_measured`/`least_headroom`)
  and the eligible `candidates` count, so the card leads with it and
  explains the pick when it departs from the `5h` convention (S6.4).
  Window docs carry `bindable`; an unclassified lane cannot win the pick
  even at 1 % left. T23's counting layer needed no changes: the scan
  already pins first-seen dedupe, cumulative→delta conversion,
  fork/copy lineage, incremental tails and cache-read separation
  (`test_codex_usage_lineage`, `test_usage_incremental_tail`,
  `test_usage_coverage` — 52 test functions).
- Verified: `tests/test_core_usage_samples.py` +
  `test_core_usage_history.py` + projection/runtime updates → 89 passed
  focused; wider usage/provider group 93 passed; Swift UsageForecast/
  UsageHistory suites green; `swift build` clean.
- Still open in W07: account/project/date filters in the Usage Center
  (transcripts are not per-configured-instance, so account filtering
  needs a session→account map) and any further dedupe/scan work the
  audit surfaces beyond the existing incremental mtime+size cache.

## W08 — Overview workspace over `list_roster` (S7 slice) — LANDED

- `CoreModel.listRoster(scope/provider/parent/since/limit)` decodes
  `CoreRoster`: rows are `CoreRosterEntry` (the `state.sessions` shape
  plus `schema`, `pinned`, `visibility`, `axes`) with per-row decode
  tolerance; `CoreRosterCounts` carries `listed` alongside the daemon's
  other totals; `coverage` passes through as JSONValue.
- `CoreSession` gains `remote` (the wire field existed; the model
  dropped it). `AgentMonitorFeed.ageText` is now public for the
  Overview's elapsed column.
- New `app/Sources/JRBarApp/Overview/`: `OverviewStore` (@MainActor,
  event-driven reload + 15 s roster cadence, selection walk, strip
  counts over the *visible* rows so list and strip cannot disagree),
  `OverviewFilter` (six presets as stored definitions —
  needs-me/working/unreviewed/this-project/this-mac/all — project
  resolved by the two-component cwd tail, never a saved session id),
  `OverviewSavedFilters` (definitions persisted in UserDefaults),
  `OverviewView` (sidebar + sortable Table + inspector shell showing
  state/outcome/review/freshness as separate facts; remote rows get a
  label, not an Open button; `Model` reads "not reported"), and
  `OverviewWindowController` (⌘O, same ↑↓/↩ monitor pattern as
  History).
- Entry points: panel footer menu, status-item menu, app menu — all
  through `store.openOverview()` / `onOpenOverview`, same deep-link
  shape as History.
- Parity: `python-roster.json` is generated by `test_upgrade_roster.py`
  (`JRBAR_UPDATE_FIXTURES=1`) and decoded by `RosterCodecTests` — the
  fields the app reads are asserted against real daemon output.
- Verified: 7 roster codec + 14 overview store tests pass;
  `swift build` clean.
- Still open in W08: the deeper inspection levels (timeline,
  context/tools, changes/results — S7.2), generated-explanation labels
  with event-id citations, and W09's read-only replay view.

## W09 slice — redacted audit export + inspector evidence labels — LANDED

- `audit_export` (core_runtime): the same `list_roster`/`list_history`
  projections, scoped identically, as `{document, format}` with
  `gaps[]` naming what is missing (no collector snapshot, ledger rows
  past `since`, a pending usage scan) and `pricing` carrying the cached
  per-provider coverage (`records`/`estimated_records`/`unpriced_records`/
  `unpriced_models`/`pending`/`stale` over 30d — never blocks on a cold
  scan). `format: "markdown"` adds the rendered `text`; `path` writes
  through `write_private_export` exactly like `export_effect_pack`.
- `audit_export.audit_export_document` redacts: `$HOME` collapses to
  `~`, secret-shaped runs (≥24 unseparated chars) become `[redacted]`,
  and only projected fields travel — no raw provider payloads (T36).
  `audit_export_markdown` renders the same facts and gaps.
- Swift: `CoreModel.exportAudit(scope:since:format:)`; the Overview
  toolbar exports via a preview sheet — the bytes previewed are the
  bytes written (Save JSON/Save Markdown through NSSavePanel).
- Inspector facts now carry S7.3 evidence chips — Reported (the source
  said it), Derived (computed from reported inputs: state word, axes,
  project), Unavailable (model: the roster does not track it).
- Verified: 6 audit-export tests + 12 roster tests pass; ruff clean;
  `OverviewExportTests` proves preview==saved bytes; `swift build` clean.
- W09 core surface complete: timeline, comparison, replay, importer.

## W09 slice — bounded Radar importer + static-topology lens — LANDED

`radar_import.py` + three commands, and the inspector's static lens
(S7.5/T38).

- `import_radar_report`: data-only — JSON parsed, capped (4 MB /
  1000 nodes / 2000 edges), normalized to `{nodes[{id,name,kind}],
  edges[{source,target,kind,evidence:"static",dangling}]}` with
  `meta{analyzer, analyzer_version, scanned_at, repository, revision,
  scope, imported_at, source_file}`; stored under the state dir with
  an index. Refusals carry codes (`not_found`/`too_large`/
  `invalid_report`). The repository and its tools are never executed.
- `list_radar_reports` / `radar_report id` — summaries and one graph;
  report ids are path-cleaned on load.
- Every imported edge is `evidence:"static"` — the importer cannot
  assert observed/configured edges; the inspector labels edges
  "static" under a "Static topology" section showing the selected
  session's one-hop provider/tool neighborhood, with an Import…
  button (`NSOpenPanel`, JSON only). T38: a static edge feeds no
  counts and fires nothing.
- Swift: `CoreRadarSummary`/`CoreRadarNode`/`CoreRadarEdge`/
  `CoreRadarReport` (tolerant decode), `CoreModel.listRadarReports`/
  `radarReport`/`importRadarReport`, `OverviewStore.staticEdges(for:)`
  + `loadRadarIfNeeded`.
- Verified: 8 `test_radar_import` cases (normalize, static label,
  caps, dangling, store/index, path-cleaning, command codes); ruff
  clean; `swift build` clean.

## W09 slice — read-only event replay surface — LANDED

The transport existed (W03 `replay_events`); the surface did not. The
Event Replay window renders the retained journal read-only.

- `CoreModel.replayEvents(limit:)` decodes journaled `CoreEvent`
  frames plus coverage: `stream`, `retained`, `dropped`,
  `resyncRequired`/`reason`. One call at the journal's own bound (512)
  reads the whole retained stream.
- `ReplayStore`/`ReplayView`/`ReplayWindowController`: persistent
  REPLAY badge + "nothing here acts" line, journal coverage line
  (loaded time, retained/dropped, resync state), and the live-attention
  count as a separate labeled indicator (T39). No mutation controls —
  the list is the journal verbatim; refresh re-reads, it never
  re-fires.
- Entry: status menu "Event Replay…" (⌘R).
- Verified: `swift build` clean; replay coverage via the existing
  `replay_events` journal tests and `CoreEvent` codec tests.

## W09 slice — run comparison — LANDED

`compare_sessions` (S7.4): two roster ids side by side on retained
facts — projected axes, transcript aggregates, ledger interruptions —
with the benchmark caveat carried on the wire, never implied away.

- `run_compare.py`: per side `{id, label, provider, cwd, lifecycle,
  mode, axes, remote, activity, interruptions, artifacts:null,
  model:null, gaps[]}`; `activity` is the `session_timeline` item
  aggregate — message/tool counts, `tool_failures`, `retried_tools`
  (tool_use ids that saw an error result), tool histogram, span —
  or `null` + `transcript_not_found`/`unsupported_provider`.
  `interruptions` counts the ledger's asked/blocked/completed for the
  agent id. `warnings` always carries `not_a_controlled_benchmark`
  plus `different_providers`/`different_workspaces`; `gaps` names
  `artifacts_not_tracked`/`model_not_tracked` — the roster has no
  per-session artifact or model record, so `shared.model` is `null`,
  never `true`.
- Swift: `CoreRunSide`/`CoreRunActivity`/`CoreRunSpan`/
  `CoreRunInterruptions`/`CoreRunComparison`, `CoreModel.compareRuns`,
  `OverviewStore` gains multi-select (`selectedIDs`, primary follows
  row order) + `compareSelected`, toolbar Compare button and context
  menu entry at exactly two selected rows, `CompareRunsSheet` —
  two-column grid with warnings banner and gap lines.
- Verified: 5 `test_run_compare` cases (aggregation, retries, gaps,
  not_found/invalid_value, end-to-end command) + 2 `CompareCodecTests`;
  `swift build` clean; ruff clean.

## W09 slice — per-session transcript timeline — LANDED

The timeline did not need a new event store: provider transcripts are
already the per-session record. `session_timeline.py` reads the
session's own transcript file and projects bounded items; S7.2's
paginate/virtualize ask is the `before`/`limit` cursor over them.

- `session_timeline` command (core_runtime): `id` resolves the roster
  row's provider/`session_id`/`cwd` (`not_found` for an unknown id);
  an aged-out session stays inspectable via `session`+`provider`
  (+`cwd`). `before` pages older items, `limit` 100/500 cap.
- `find_transcript` matches uuid-in-filename under
  `~/.claude/projects/**` (cwd-slugged project dir first) and
  `~/.codex/sessions/**`; other providers answer `unsupported_provider`,
  a missing file `transcript_not_found` — named gaps, never empty
  success.
- Items: `{seq, at, kind, role, name, text, tool_use_id, is_error,
  sidechain, model, uuid, parent_uuid, origin:"transcript",
  recorded_at:null, untrusted}` — kinds `message`/`tool_use`/
  `tool_result`/`turn_end`; tool pairs link on `tool_use_id`; `at` is
  the row's own stamp (occurrence vs ingestion distinguished honestly:
  ingestion time was never recorded). Tool output and assistant text
  carry `untrusted: true` (T44 — content, never a command); text is
  600-char bounded and secret-run redacted.
- Bounds: 64 MB file cap (`transcript_too_large` gap), 5000-item cap
  (`timeline_item_cap` gap), 4000-file discovery bound.
- Swift: `CoreTimelineItem`/`CoreTimelinePage` (tolerant decode, source
  flattened), `CoreModel.sessionTimeline`, `OverviewStore` timeline
  buffer pinned to `timelineSessionID` (a late reply cannot write
  another selection's page), inspector Timeline section with
  occurrence-clock column, tool-pair icons, per-gap honest text and
  "Load earlier".
- Verified: 14 `test_session_timeline` cases (pairing, paging, gaps,
  redaction, occurrence-vs-ingestion, command resolution incl. direct
  ended-session lookup) + 3 `TimelineCodecTests`; `swift build` clean.
