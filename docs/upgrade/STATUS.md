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

## W26 slice — OpenCode capability bridge — REMOVED

- Removed 2026-09-24: nothing ever called it. Restore it with
  `git show 50fdc2c0:src/jrbar/opencode_bridge.py` when provider
  management needs it.
- `src/jrbar/opencode_bridge.py` (was new): probes a running `opencode
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

## W25 slice — coordinator policy — REMOVED

- Removed 2026-09-24: nothing ever called it. Restore it with
  `git show 50fdc2c0:src/jrbar/coordinator_policy.py` when the composer
  lands.
- `src/jrbar/coordinator_policy.py` (was new): the assistant layer's
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

## W24 slice — utility-generation policy — REMOVED

- Removed 2026-09-24: nothing ever called it. Restore it with
  `git show 50fdc2c0:src/jrbar/utility_generation.py` when the adapter
  lands.
- `src/jrbar/utility_generation.py` (was new): the decision layer a
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

## W21 slice — shared JSON-RPC stdio transport — REMOVED

- Removed 2026-09-24: nothing ever called it. Restore it (and
  tests/test_acp_transport.py) with `git show 50fdc2c0:<path>` when the
  first adapter lands.
- `src/jrbar/acp_transport.py` (was new): the bounded transport every
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

## Visual cleanup — pet chrome removal, peek material, under-band clearance — LANDED

Owner-reported glitches on the installed 0.9.8 build: the buddy sat on a
dark glass blob crowding the notch, and the peek/pinned card rendered as
a `.regular` `NSGlassEffectView` — the "random liquid glass pill".

- `BuddyPanel` (free pet): pill chrome removed entirely — the hosting
  view is the content view on a transparent borderless panel; no
  material, no window shadow (a shadow hugging the caption read as a
  smudge). The creature floats bare; the caption got a text shadow for
  legibility over arbitrary content.
- `NotchHUDPanel` (docked buddy): the hosting view now moves between
  two containers — `chrome` (`NSVisualEffectView` `.hudWindow`) for
  toasts, which are real UI and keep a backing, and a plain clear
  `NSView` for the buddy, which hangs under the notch bare. Shadow
  follows the chrome only.
- `ScreenBarTooltipPanel`: `.regular` glass removed — the peek and the
  pinned card wear `.hudWindow` unconditionally (the
  `JRBAR_PLAIN_MATERIAL` fork in these three surfaces is gone; the
  deliberate surfaces — main panel, first-run card, deck rail, why
  popover — keep their materials).
- Under-band clearance: `NotchHUD.panelClearance` reports the vertical
  room the HUD panel claims (docked buddy or toast);
  `ScreenBarInteraction.underBandClearance` is wired to it in
  `AppDelegate`, so the peek drops below whatever is hanging under the
  band instead of landing on the pet — they shared the same level and
  centre before.
- Verified: `swift build` clean; 20 buddy/interaction tests + full
  Swift suite (557) green. Real-screen overlap check is on hardware —
  geometry is asserted in code, not screenshot-verified here.

## Notch-side polish — bare wings, dot buddy, swipe gestures, aquarium casting, fold smoothness — LANDED

Follow-up owner pass on the installed build: the wing capsules read as
floating pills, the pet's name tag was always on, the aquarium doubled
its labels, fold still juddered, there were no Alcove-style swipes, and
the Overview was undiscoverable.

- `ScreenBarWingsView`: the translucent black capsule is gone — wings
  draw bare (icon + word, `.primary` so they follow the menu bar's
  light/dark like a native status item). Same hit rects, same tones.
- Docked buddy is now the status dot: idle dims it, one working session
  tints it, a plural count earns a number; open asks still wear "!".
  The name tag exists only under the pointer (space reserved, no jump),
  driven by a `mouseEntered/Exited` tracking area on the hosting view —
  its own area only, so SwiftUI's internal tracking survives.
  Floating keeps the character (or Mini), with the same hover-only tag.
- Alcove-style band gestures: a press dragged down expands the pinned
  card, dragged up while pinned collapses it (`swipeOutcome` is the
  pure truth table, threshold 14pt). Clicks resolve on release now so a
  drag can claim the gesture first; outside presses still unpin on down.
- Pinned card footer row: "Agent Overview ⌘O" — the roster was real
  (⌘O, status menu, More menu) but invisible in the surface users
  actually open. Wired to `OverviewWindowController.show()`.
- Aquarium: per-provider species casting. `AquariumSettings.
  speciesOverrides` persists `[provider: species]`; the inspector's
  picker recasts every fish from that provider at once ("Automatic"
  returns the table species). Duplicate nameplate fixed — the fish
  wearing the hover/tap tag skips its always-on chip.
- Fold: shipped defaults now 65°/Fog/shade 0.7 (both past default sets
  migrate; deliberate files survive). `LidTracker` renders a
  piecewise-linear fit through sensor samples — each edge eases in over
  the interval it took to arrive, landing on the newest reading as the
  next lands. No extrapolation, no added lag, no 10 Hz staircase
  re-energizing the spring. Velocity measures edge-to-edge.
- Verified: `swift build` clean; full Swift suite 562 green (30 FoldMath
  incl. a new "render never steps" bound, 9 interaction incl. swipe
  truth table, 10 toys-state incl. chained migration). Python suite
  unchanged (3516). Hardware lid-travel and on-screen gesture feel
  remain device-verified.

## Notch polish pass 2 — opaque wing pills, trackpad swipes, peek corridor — LANDED

Owner re-check: bare-text wings read as stray menu-bar labels, swipes
did nothing, and the peek flapped again.

- Wings are opaque `.black` capsules again — flat black beside the flat
  black notch is the notch-extension look; translucent read as a
  smudge, bare text read as stray labels. Text back to white, 11 pt.
- Trackpad swipes now work: a two-finger swipe is `scrollWheel`, never
  `leftMouseDragged` — the interaction reads the same
  phase-accumulated, `isDirectionInvertedFromDevice`-normalised stream
  the island's hosting view does (`hasPreciseScrollingDeltas` +
  non-empty `phase`, momentum ignored), threshold 40 pt to match the
  island's vertical read. Fingers down expands, fingers up collapses a
  pinned card; the click-drag path stays for mice.
- Peek jitter: the card drops below the docked buddy's HUD frame, but
  that frame wasn't in the hover union — crossing the pet on the way to
  the card counted as leaving, so the peek hid and re-armed. The HUD's
  occupied frame now joins the union while the card is up
  (`underBandRegion`), closing the dead zone.
- Verified: `swift build` clean; 9 interaction tests green.

## Notch polish pass 3 — flap fix, hugging pills, scroll swipes — LANDED

Owner re-check on the installed build: hovering the band opened and
closed the peek nonstop, and the wings still did not read like the
reference.

- The flap: `geometryChanged` hid the tooltip on ANY wing-rect change.
  State churn toggles a slot → peek killed while the pointer was still
  on the band → the 180 ms hover re-armed it → repeat forever. Now it
  re-anchors under the band's current rect and re-evaluates the hover —
  the peek survives geometry churn it has no business dying to.
- The wings: the claim rect was being drawn as the capsule and the
  content centered inside — a ~110 pt pill floating far off the notch.
  The capsule now hugs the notch side of the claim and sizes to its
  content (bounded text so a long label truncates instead of riding
  onto the notch). Opaque black, 11 pt, matches the notch-extension
  look the references show.
- The caption flicker: the buddy's per-tick breathing relayout
  re-registered the hover tracking area every frame, refiring
  enter/exit — the name tag strobed. It now re-registers only when the
  bounds actually change.
- Scroll swipes (pass 2) and the drag path both live: fingers down
  expands, fingers up collapses a pinned card.
- Verified: `swift build` clean; 562 Swift tests green.

## Notch polish pass 4 — the wing is a lobe, not a pill — LANDED

Owner screenshot review: the wings still read as floating menu-bar
pills — boxed icon tile plus text — nothing like the references.

- The icon tile: `ProviderTile` draws an app-icon badge (accent fill +
  stroke rounded square). Replaced in the wing with the provider's bare
  glyph in its accent — a plain mark against the black, like the
  references.
- The gap: `wingSlotRect` carved `wingContentInnerReserve` (16) out of
  the drawn claim, so the capsule ended 16 pt short of the notch and
  floated in open menu-bar space. The claim now anchors its notch-side
  edge AT the notch edge and reaches outward through the measured room;
  the reserve stays in `contentWingExtent` purely as a viability margin
  (a flank that tight is not honestly usable).
- The seam: a capsule cap touching the notch edge meets it at one
  tangent point. The chip now pads its notch side by `notchSeam` (12 —
  past the cap radius) so the black runs under the bezel and the
  silhouette meets the notch on a straight edge: the lobe-merged look.
  Content stays clear of the bezel; the hit claim is unchanged.
- Verified: `swift build` clean; 562 Swift tests green; geometry suite
  updated for the anchored claim.

## Notch polish pass 5 — real ears, wing gestures, device notices — LANDED

Owner feedback: the wings still didn't match the bezel the way the
reference's do, there was no swipe to dismiss or summon them, and they
never spoke for device events like headphones connecting.

- Silhouette: the claim now spans the notch's own depth at the window's
  top — the drawn shape is an `UnevenRoundedRectangle` flush with the
  screen's top edge, square where it runs under the bezel, one rounded
  outer-bottom corner at the notch's own ~10 pt radius. The ear is the
  bezel's arm, not a centred stadium. The 12 pt submersion seam stays.
- Wing gestures (`wingSwipeOutcome`, pure + 5 tests): an outward flick
  on a wing dismisses that side — drag or trackpad swipe, resolved by
  dominant axis against the vertical expand/collapse. A horizontal
  swipe on the band summons dismissed wings back. A dismissed wing
  revives when its slot's content changes — the dismissal was of what
  it showed, and a new state is new information.
- Device notices: `AlcovePowerMonitor` transitions (charger in/out, on
  battery, fully charged — `AlcovePower.notice`'s own wording) plus a
  new `ScreenBarAudioMonitor` — a CoreAudio listener on the default
  output device, the honest "headphones took the route" signal with no
  Bluetooth SPI or entitlement. A notice holds the right wing for the
  island's capsule `life` (2.4 s) with a 30 s same-subject cooldown
  against reconnect flaps, then the slot it replaced returns.
  `screen_bar_wing_notices` gates the monitors (default on); they only
  run while the wings are actually up and never while the band follows
  an Alcove capsule.
- Verified: `swift build` clean; 567 Swift tests green.

## Notch polish pass 6 — one tray, not two ears — LANDED

Owner: "still feels nothing like alcove but better direction." The
missing piece was structural — the reference is not two lobes beside
the notch; it is one continuous shape that wraps under it.

- The tray: a single `UnevenRoundedRectangle` spanning outer-left claim
  to outer-right claim — under the bezel in between — with a 6 pt chin
  below the bezel's bottom edge (`wingTrayChin`). Flush with the
  screen's top edge, bottom corners at the notch's own 10 pt radius.
  The ears are the tray's visible ends; the chips draw content only.
- The window grows by the chin while any wing claims room
  (`windowFrame(chin:)`), so the band drops exactly the chin's depth —
  tray + light reads as one device. Empty wings collapse it back.
- The tray joins the hover region, so moving from an ear onto the chin
  keeps the peek — it is our drawn surface.
- Notch-less screens keep the capsule chip hugging the band's end.
- Verified: `swift build` clean; 567 Swift tests green.

## Notch polish pass 7 — content-sized ears — LANDED

Owner: "jt still looks & feel like shit compare to alcove." The tray
was still claim-wide — ~126 pt of black each side no matter how short
the words — so `Working` floated mid-menu-bar inside a slab. Alcove's
island is exactly as wide as its content.

- The ear is now content-sized: `earWidth` measures the words plus the
  mark plus padding, capped by the claim, and hugs the bezel edge.
  `Working` sits against the notch's left edge; `100%` against its
  right — one tight island, not two text clusters in a black void.
- Hit regions follow the drawn ear, not the claim: empty claim space
  is no longer a hover dead-zone magnet.
- Ear content centres in the full tray depth (notch depth + chin),
  dropping to the island's own visual centre rather than menu-item
  height.
- The island morphs: tray/ear bounds and chip presence spring
  (0.22 s response, damped) while a claim persists; Reduce Motion
  skips it. Window-frame snaps stay instant.
- Notch-less chips keep the claim rect and their own capsule.
- Verified: `swift build` clean; 567 Swift tests green.

## Notch polish pass 8 — symbols-only ears — LANDED

Owner: "lets not do text, only icons & symbols … should feel like an
apple native feature." Words in the ears never read native — macOS
complications are marks, not labels — and "10…" showed a meter
truncating inside a crowded claim.

- The ear is a mark, never words: provider glyph for the left state
  ear (tone-coloured), a thin quota ring filling to the meter fraction
  with the provider mark inside for the right ear, an SF symbol for
  notices, a resting dot when a slot has words but no mark.
- `ScreenBarWingSlot.meter` (0…1) carries the usage fraction;
  `percentText` still feeds the peek and VoiceOver — the words moved,
  they were not lost.
- The ear is a fixed 30 pt lobe hugging the bezel at tray depth —
  the claim stays only as the room ceiling, so native menu items a
  few points further out are never crowded. The island is now at most
  notch + 60 pt.
- Accessibility keeps the slot's text as the label.
- Verified: `swift build` clean; 567 Swift tests green.

## Gesture pass — the sign bug and the dead feel — LANDED

Owner: "gestures don't work … get them working right & better."

- The real bug: the scroll path fed scroll-space deltas to
  `swipeOutcome`/`wingSwipeOutcome`, which read pointer space. Under
  natural scrolling a downward pull accumulated positive — a pull-down
  fired collapse (or nothing), and an outward ear flick read inward.
  `scrollFingerDelta` recovers the finger's direction; both gesture
  feeds now meet the pure functions in one convention, pinned by two
  sign tests.
- The dead feel: a pull that never reached the threshold did nothing
  visible. A downward pull past 25% now slides the peek out early;
  an ear being pulled rides the finger with `tanh` resistance and
  fades as it leaves, springing home when the flick doesn't commit.
- Flick commit: a gesture that lifts past ~55% of the threshold on
  `.ended` still lands; `.cancelled` (palm) never commits.
- Found while there: pinning while the peek was up swapped to the
  taller card layout inside the peek's frame — the card clipped until
  focus churn refit it. `setPinned` re-presents immediately.
- Verified: `swift build` clean; 569 Swift tests green (+2 sign tests).

## First-class pass — the notch's own corner, the device orbit — LANDED

Owner: "make it feel even more first class … same radius rounding as
the notch … get the user's machine spec, or a dropdown asking the
MacBook … a menu symbol like the new Apple fold one — Wi-Fi, cellular
and battery nested in one indicator, dots for signal, a ring for
battery, blue/green/grey."

- The tray's bottom corners now follow the notch's own radius: the
  hardware cutout measures ~8 pt at the bottom on every notched
  MacBook (4 pt at the top, which never meets us) — the hard-coded 10
  over-rounded by a visible two points. `NotchProfile` resolves it:
  `auto` reads `hw.model`, the named MacBook profiles pin it, and
  `custom` takes the `screen_bar_notch_corner` slider (4–16 pt).
  Settings › Screen Bar shows the detected model ("Detected:
  MacBook Pro") under a new Notch shape row.
- `NSScreen` gives the slot's size, never its corner — verified on
  this machine (Mac16,8: 185×32 pt slot, exactly the published MBP14
  figure). No public or IOKit surface carries the radius, so the
  measured constant plus an override is the honest shape of it.
- The ear's mark now centres inside the bezel's own height; the chin
  below the bezel is tray structure, not content room.
- New menu-bar icon style **Device orbit** (`orbit`): the
  folded-corner grammar — a battery ring broken at the bottom for
  four signal dots, the Wi-Fi mark centred inside. Blue while
  associated, grey for a radio off or unreadable, the ring green
  while charging and red under a fifth. No number: the arc is the
  charge, the figure lives in the tooltip and VoiceOver. Fed by a
  5 s CoreWLAN + IOKit poll (`StatusDeviceMonitor`) that exists only
  while the style is selected; a dBm that drifts inside a dot bucket
  reuses the cached image.
- Macs have no cellular — the icon doesn't pretend: the radio read
  is Wi-Fi, the honest cellular slot on this hardware is nothing.
- Render proofs (`JRBAR_RENDER_PROOF=1`) write the roundel's six
  states and the tray silhouette to /tmp for eyeball review; the
  tray render and a live screencapture of the installed build both
  show the bezel sitting inside one continuous shape.
- Verified: `swift build` clean; 581 Swift tests green (+12); signed,
  installed, running.

## Daily-driver pass — menu bar spacers, one dock, notch shoulders, resident fish — LANDED

Owner (2026-09-15, grilled then "lgtm, get it all working … go until
full done"): daily-driver bar (quit Alcove, DockDoor, Ice, Bartender for
a week), WIP floor committed first, Bartender-style collapse, agent
HUD first on the notch, Enhanced-only dock, aquarium/Fold/buddy after
the utilities, closed hardware list (Mac, Creator Micro 2, Screen Bar,
LED strip, hinge), captures + checklist as the verification.

- Verified live before designing: a 3 000 pt status item is parked by
  macOS 26 itself; a 250 pt item inserted mid-row stays and pushes
  cmux/ChatGPT/our own controls into the native overflow with no
  holes. Screenshots cannot show `sharingType = .none` windows (covers,
  Item Bar, island) — verification is the AX listing and the
  `devin.jrbar:menubar` plan log.
- Menu Bar: positional sections, the chevron and the always-hidden
  control as spacers, overrides-only covers, cover-era map cleared
  once, learned fit caps, the native overflow button listed so stacked
  items read as parked, a pushed always-hidden control recognised as
  pushed. An automatic reseat of the controls next to JR-Bar's own
  item was built, run live three times, and removed: the preferred
  position is a sort key, not an x, and the correction loop diverged
  on the real bar. 21 new tests.
- Dock: Replace cut (−4 000 lines); `AppleDockControl.restore()` runs
  on every apply so an old hide is undone; Enhance gained TCC caching,
  a cached dock list, click-away, frame-matched thumbnails, off-screen
  windows, close/minimize/Hide/Quit, glass, large cards.
- Notch: shoulder layout (`NotchIdleLayout`), bare under the Screen
  Bar's ears, `MediaFeed` (one monitor, refcounted readers),
  `CoreProviderUsage.headlineWindow` as the one meter rule, slot-based
  anchors, one reused height probe.
- Aquarium: `FishCare.label/provider` via `identify`,
  `AquariumGame.residents`, `Fish.isResident`, the reducer appends
  residents after the roster and hands a returning session its fish
  back.
- Services check: daemon 0.9.8 answers with 9 providers (6 ready;
  Cursor needs a browser import, Gemini a Code Assist project id,
  openai-api disabled), Screen Bar + SidePulse Pro + Dot connected and
  writing.
- Not verified by eye: the display was asleep and the session locked
  for the whole pass. Fold's feel, the reseated chevron, the dock
  panel and the island shoulders need the owner's checklist.
- Verified: `swift build` clean; 929 Swift tests green; 3 537 Python
  tests green; Ruff clean; 0.9.8 packaged, Developer ID signed,
  installed.

## Daily-driver pass, evening — the icon is the boundary — LANDED

Owner: "the menu bar still isn't working. None of it feels right … make
this a finished, good product" and "the computer should not go to sleep
if an agent is running."

- With the display awake the bar was photographed at every step. The
  separate chevron item hid one item by default (its slot was macOS's
  choice), so JR-Bar's own status item is the boundary now:
  `StatusItemController` hosts `boundarySpacer`, folds the icon to the
  spacer's right end with a `‹` hint, takes the reveal click on the
  blank part, carries a "Hidden Menu Bar Items" submenu, and says in
  its tooltip how many items are tucked away.
- Three sizing models were tried live and the survivors are: a *fit
  edge* per screen (54 pt right of the notch, moved right only on the
  «'s proof of overflow, remembered in UserDefaults); no learning of
  the edge from the «'s position (a transient reflow collapsed the
  spacer to zero that way); no "stacked frames are parked" rule (stale
  third-party AX frames overlap while both are drawn).
- macOS's « draws above any panel of ours — a cover under it hides
  nothing — so it stays, and the Screen Bar's right ear narrows to
  stop short of it (19 pt, ring intact).
- The hover/click hit test excludes our own item's frame (the spacer
  is the zone), the reveal gestures are confined to the blank stretch,
  and the settings card was rebuilt: how it works, what is hidden now,
  the reveal gestures, then Overrides and Advanced.
- Dock: the list has no subrole on macOS 26; the watcher keys on the
  role, refreshes fast near the auto-hidden edge, and logs its gates.
- Power: `keep_display_awake` defaults on; the daemon confirmed
  `PreventUserIdleDisplaySleep` held the moment it was set.
- Verified by eye (unlocked): cmux, ChatGPT, Tailscale and Creative
  Cloud gone; ring · « · blank · ‹ icon · Passwords · Wi-Fi · battery ·
  weather · clock; the spacer settled at 220 pt in one pass, no
  corrections; stable across a minute of listings.
- Not verified by eye: the hover/click reveal cycle and a Dock preview
  — both need a hand on the pointer.
- Verified: 937 Swift tests, Python power suites, fast gate, Ruff; the
  Mac runs the 19:49 build.

## Evening, second pass — the dance, the slab, the Dock — LANDED

Owner (screenshot at 8:46 PM): "the menu is literally just dancing
and constantly moving … fix the top bar, make the notch better, make
the dock usable, clean up the entire app."

- The dance, from the log: a two-state flap every 370 ms, 90 cycles
  in two minutes. The separate always-hidden status item (`···`)
  traded places with the JR-Bar icon on every reflow (a length write
  re-sorts the bar; the two keys straddled the spacer's range), and
  each swap changed the boundary's frame, so the plan asked for a new
  length, and the bar reflowed again. Removed the second item; the
  always-hidden section is override-only. Length writes are damped
  (two agreeing passes, one-second cooldown; reveal/hide/parked/
  overflow write at once). A fit-edge lesson needs two fresh listings
  (the launch handoff produced a false one and ratcheted the edge
  right 902 → 910 → 926).
- Notch: with the Screen Bar's ears on, the island was a bare black
  slab 12 pt past the notch each side, nothing in it, eating clicks.
  Bare = exactly the notch now; shoulders are independent widths;
  hover 0.35 s and gated on the setting; card 320 pt; copy honest.
- Dock: panel clamped to the screen and re-anchored each tick while
  hovered (the Dock slides in under it); level dockWindow − 1;
  `acceptsMouseMovedEvents`; seam grace 0.12 s; no panel for a
  windowless app; plain `activate()`; thumbnails matched by row id;
  tiles cached 0.25 s; `sharingType = .none` (dev escape
  `JRBAR_CAPTURE_CARD`).
- Verified: 940-odd Swift tests green; installed and watched — 4
  plan lines in the first ten seconds after launch, then none.
  Dock previews fired for T3 Code, Claude and Zen in the log before
  the fixes (so the pipeline runs); the panel's placement after the
  fixes needs a hover to see.

## Late evening, third pass — the shift, the ears, the Dock panel — LANDED

Owner (9:35 PM): "Notch is coming in from the side … the wings don't
respond nearly as well as Alcove … the menu bar is still god-awful …
the dock hover is off-center."

- The 9:31 PM flap in the log was not the two-item dance (fixed) but
  the whole bar shifting left 56 pt under macOS's screen-recording
  indicator — which every Dock thumbnail capture summons — and the
  spacer chasing it. `CGWindowListCreateImage` is unavailable on this
  SDK, so captures stay ScreenCaptureKit; the spacer now waits 5 s
  before any shrink and a shift never teaches the fit edge. During
  the shift the boundary sits in macOS's overflow and returns on its
  own; nothing left of it can repack (overflow is the run's tail).
- Ears: the interaction's hover region now drives the island's hover
  (`onIslandHover` → `NotchToy.bandHover`), `pointerOnBand` keeps the
  collapse timer from firing while the pointer is still on an ear,
  island hover delay 0.12 s, expand response 0.34.
- "From the side": the frame spring is provably centred every tick
  (`growStaysCentred`); the island's grow swells down from the notch.
  What he saw is unverified — possibly the tray/LED coupling — needs
  his eyes with `JRBAR_CAPTURE_CARD=1`.
- Dock panel: hosting view fills the glass (autoresizing) and the
  panel is sized from `intrinsicContentSize` — the content sat in the
  panel's corner.
- Reveal gestures and rehides log to `devin.jrbar:menubar` so the next
  "hover did nothing" has evidence.
- "From the side", found by the second pass: `NotchIslandWindow`'s
  hosting view had default sizing options; a 320-pt card in a 200-pt
  window mid-grow pinned to minX and marched with it. `sizingOptions =
  []` + autoresizing (the NotchHUD idiom). Idle window is symmetric
  again (wider shoulder both sides, content hugs the notch) so every
  face shares the notch's centre.
- Maintenance from the Agents/toys sweep: per-utility apply in
  `UtilitiesStore`, aquarium timer gated on `isOn` with a deinit,
  `clearFinished` passes ids, buddy timeline pauses, AX casts guarded,
  stale comments fixed. Left: `UtilitiesState.enabled` is persisted
  but never read (the page has no master switch yet); the card's
  "Undo clear" has no ticker; `MenuBarZones`/`MenuBarItemMover.plan`
  are test-only.

## 2026-09-16 — the audit, the Fold grey, the concealer — LANDED

Owner: "audit all of our systems … compare ourselves against them";
"the fold … super gray now instead of black."

- Audit: `docs/archive/AUDIT-2026-09-16.md`. The reframing fact: this Mac is
  macOS 27.0 (26A428). Spacer hiding was the wrong mechanism for it.
- Fold grey = the Frost knob at its 0.65 default; default 0 now, the
  shipped value migrates, his file set to 0.
- Menu Bar: `MenuBarConcealer` (assessment-mode assertion), per-app
  map `concealedApps` seeded from the spacer plan, click bridge for
  the agent's items, spacer engine as fallback. Verified after
  install: see the ledger line below.

## 2026-09-16 afternoon — energy, flush ears, Dock offset — IN PROGRESS

Owner: "it's this app draining the battery"; "the notch is expanding
past it"; "the dock is offset whenever it shows a preview".

- Energy, measured on an idle desk before: app 3.1%, daemon 2.3% with
  10–30% bursts. App causes: an AX round trip to every running app
  every 2 s (four concurrent threads), three pointer polls at 10–20 Hz.
  Daemon causes: a whole-table `ps` on every state build, `ioreg`
  forks for the lid, `diskutil` per mount, and — the steady one — the
  Alcove follower listing every on-screen window through Quartz every
  1.5 s while Alcove is not running. Fixes: known-owner AX scans (full
  walk every 20 s / on launch-quit), adaptive polls (4 Hz when far),
  process table cached 10 s, liveness sweep 15 s, IOKit lid read,
  Alcove probe gated on the process. App after: 1.2–1.8%. Daemon after
  warm-up: measurement pending (a fresh daemon spends minutes scanning
  transcripts; measure after 10 min).
- A SIGUSR1 stack dump was added for attribution and made opt-in
  (`JRBAR_STACK_DUMPS=1`) after a signal mid-syscall killed the daemon.
- Ears: tray chin 6 → 0, ear width 30 → 24; the black ends at the
  hardware's edge (notch 185×32 on this Mac, menu bar 33).
- Dock: magnification is on here; tile frames are read live while a
  panel is up, and each preview logs tile/pointer/size/panel geometry
  (`dock] preview geometry`) so the offset can be read from the log
  after the owner's next hover.
- Menu bar: unchanged this pass — the concealer waits on notarization
  (the `jrbar-notary` profile).


## Parity pass — Dock hold-out, Notch hover, Agent HUD — LANDED

Owner: "make the utilities as good as Bartender 7, DockDoor Pro,
Alcove". Audit order: Dock → Notch → Agent HUD.

- Dock: the preview panel now holds the Dock out through the private
  `CoreDockSetAutoHideEnabled` (probed via dlopen, fail-soft, crash-safe
  restore on close/exit — `DockHold.swift`); cards gained Fullscreen and
  New Window verbs, the dead `onOpenApp` path for windowless apps is
  replaced by a real Open, and tiles past the configurable compact-list
  limit render a row-per-window list. 35 DockEnhance tests.
- Notch: the hover tell lives on the Screen Bar ear chips (outward swell
  only — the bare island could never show it); arrivals from the
  menu-bar row wait the third-of-a-second floor while a direct island
  hover keeps 0.12 s, and ear→island crossing keeps the original
  deadline; hover-open suppresses while a fullscreen app is frontmost
  (presentation options); an optional haptic tick fires on open
  (`NotchSettings.hapticTick`, tolerant decode).
- Agent HUD: smart suppression — an ask whose terminal pane is
  frontmost keeps its banner but loses the burst, the pulse and the
  chime (`AskingPane` mirrors `answer_local`'s bundle + proc_pidinfo
  ancestry proof; the stage's noise re-decides on every frontmost-app
  flip, gated by `AgentOrganizerSettings.quietWhenPaneFrontmost` —
  app-state, not the daemon document). Incidents ride the wire now:
  `core_projection` emits the `incident` the usage runtime already
  stamped; `CoreProviderUsage.incident` decodes it; the ear's ring
  flips amber, the panel row and Usage Center badge it with the feed's
  own text. Countdown on the ring: `NotchIslandMeter` carries
  `resetsAt` + the lane's span (`UsageWindowLabel.windowSpan`), the ear
  draws a drain arc inside the fill, the peek and the island card name
  it in words.
- Verified: swift build clean; 970 tests across the four Swift targets
  pass (incl. new AskingPane, EventPolicy suppression, meter/reset
  suites); the projection's Python tests pass with `incident` on the
  fixture. Docs: CHANGELOG, UTILITIES, FEATURE-MATRIX, TOY-PARITY.
