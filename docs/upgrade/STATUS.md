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

(Remaining packages W06+ proceed in the spec's dependency order; rows are
added as work lands.)
