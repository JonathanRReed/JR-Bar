# Changelog

All notable changes to JR-Bar are documented here.

## 0.9.4 (unreleased)

- Black means black on a linked Screen Bar. The mirror's luminance lift
  was a flat floor, so every dim code — embers, fade tails, codes the
  strip's write boundary crushes to off — painted the same constant glow
  the hardware does not have. The lift is now a continuous curve that
  keeps dark beats dark: `#000000` stays exact, near-black stays
  near-black, and a mid-dark tail gets only a partial lift. The surface
  also reports the program's own `brightness` (the strip's) rather than
  the bar's ambient plan, and the housing rim follows the live Minimum
  glow setting and turns off entirely while the band shows no light.
- Animations no longer restart on brightness noise. Ambient-lux drift
  was baking a new `brightness N` into the program text every refresh —
  a real firmware write, a new anchor, a visible restart on the strip
  and the bar alike. Emitted brightness now has hysteresis: sub-
  perceptible drift is held, deliberate settings writes always pass,
  and fades to zero are never held. A republish with the same program
  and a nil or unmoved anchor no longer recompiles anything; a moved
  anchor re-aligns by replaying the plan, not rebuilding it; and a
  window move that changes neither plan nor phase is a no-op.
- A reassert now publishes the program the strip is actually running.
  Reasserts write the steady-state variant (no approach frame), so the
  strip's loop is shorter than the published text — the bar drifted a
  little further off phase every lap. Both `last_program` and the
  nominal mirror now record the running variant.
- The document dedupe now works: state and lights frames carried ticking
  fields (`now`, ages, now-relative forecasts) that made every broadcast
  look changed. Publish-time compares significance with those volatile
  paths stripped — a quiet rebuild costs one compare instead of a full
  broadcast-and-redecode on every client.
- `menu_bar_icon_style` no longer bounces: the daemon accepts all five
  app styles (it only knew the three glyph styles, so picking a meters
  or dots style reported "the core kept 'glyph' instead").
- Copy sweep, round two: the daemon is "the monitor" in user-facing text
  (tooltips, toasts, empty states, errors); the Screen Bar chip says
  "shown"/"hidden" instead of borrowing "connected"; Ask/Error carry
  their Lighting names in the assign sheet ("Ask — needs you",
  "Error — failed") with a caption explaining the reservation and why
  only two states are offered; the Active scene subtitle says what it
  does; the Stream Deck card gained its own serve toggle; the integer
  slider shows its unit; the rail and the band ease in and out instead
  of snapping (Reduce Motion keeps the instant swap); "Details" is
  "Usage Center"; elapsed-time units read the same everywhere.
- Small bounds: the per-session extras cache is capped; the lights build
  asks for the device list once instead of twice.

## 0.9.3

- Linked Screen Bar mirrors the strip's program, not a second rendering
  of it. The bar and the SidePulse shared an anchor but drew from
  different palettes (agent colours vs. mode colours), so the same beat
  could read as two different lights. When linked, the bar now presents
  the strip's nominal program — timing and hue identical — lifted to the
  display legibility floor, hue and saturation intact. Drive bytes stay
  on the strip: the bar never wears the die's calibration.
- One word per thing, everywhere. "Needs you" is the same phrase in the
  panel, the menu bar, and the effect targets; the Dot's roles read
  Mirror the strip / Alert beacon / On its own (they were Extend /
  Ask beacon / Status while the wire said linked / beacon / solo); the
  two link toggles say what they do — "Mirror the hardware strip" and
  "Dot follows the strip"; blend-mode names and descriptions now match
  between the app and the daemon; "Everywhere" is one scope, one name;
  percentages are "42%", window names match their menu items, and
  internal words ("core", raw enum names like `command_confirmation`,
  transfer-generation numbers) no longer leak into the UI.
- The first-run card tells the truth about the light language — a beat,
  not a strobe (nothing strobes), red means broke — plays a real
  LEDStripPreview instead of a gradient, eases out instead of
  vanishing, and points at the menu-bar icon.
- Screen Bar settings live on one page: the General section moved to
  Devices & Screen Bar; the Devices card no longer duplicates the
  serve toggle (status stays, the switch lives in Remote).
- Frame dedupe on the wire: identical state/lights/settings documents
  are never broadcast twice — a poke that changes nothing costs one
  encode instead of a full broadcast-and-redecode on every client.
- Terminal and TTY lookups are keyed by (pid, process start) instead of
  pid alone: a reused pid can no longer inherit the previous owner's
  terminal, and both caches are bounded.
- The status menu's Lights line says what the band is doing — "monitor ·
  working · following Alcove" — instead of render-pipeline diagnostics.

## 0.9.2

- Auto-dim's ambient curve is calibrated for real rooms. The sensor that
  faces you reads ~50-150 lux in a normally lit space; the old defaults
  treated 400 lux as "bright" and 5 lux as "dark", so every indoor room
  pinned the bar near its 10% floor. The defaults are now 15 lux → 35%
  rising to full at 150 lux. Lighting › Auto-dim also gets a "use this
  room" calibrator that sets the marks from the live reading.
- A resolved ask can no longer hold a session on "waiting". The
  canonical projection counted resolved request tombstones as open
  requests, so a Codex permission prompt kept the row — and its share
  of the light — waiting after you'd answered. Only live requests whose
  next actor is the user pin a session now.
- The four long-standing red tests are fixed, not skipped: the battery
  LED tests get a controllable clock, the Grok-payload routing test
  stops inheriting the host's process ancestry, and the Codex
  permission test is the fix above. The Python suite is fully green.
- Clock continuity heals: a freshness-only source loss used to pin the
  daemon at "uncertain" forever; it now ages out after the timing lease
  while a genuine source loss still requires two confirmations.
- Effect Studio answers "what plays on Devin?" — a What plays where
  section groups each live provider's motion, its instance and semantic
  rows, and device rows in one place, and the assign sheet re-hydrates
  parameters per (scope, target) instead of showing the last tuning.
- Stream Deck is in the hardware section: a card on the Devices page
  shows the status endpoint, copies the bearer token, toggles serving,
  and a minimal polling plugin scaffold lives in `integrations/streamdeck/`.
- First launch gets a one-card orientation — what the band is, what the
  marks mean — hung under the band after the hook-install toast, once.
- Reduce Motion now reaches the band: the Screen Bar holds a still frame
  instead of animating, and the band, preview strips, and panel rows
  speak VoiceOver — including which session the band is showing.

## 0.9.1

- The default multi-agent look is Smooth (`color_blend`): one seamless
  light mixed from every active agent's colour. On the Screen Bar —
  which already blends each LED with its neighbours — Everyone's
  alternating per-agent blocks averaged into a shifting grey seam; a
  single mixed colour stays one calm band however many agents report.
  Existing `colors.blend_mode` values are untouched; Everyone, Split,
  Spotlight, One at a Time and Status Only remain in the picker.
- The Assign sheet can no longer promise what the daemon won't deliver.
  Its default draft is Provider scope aimed at a provider this Mac has
  actually seen, the State picker only offers the routable targets
  (Notification, Done), the Provider picker lists live providers first,
  the Project target accepts real origin labels ("Claude in VS Code")
  instead of demanding an identifier that can't exist, and the dead
  "Screen Bar" device target is gone. The sheet also says when a draft
  would replace an existing assignment, surfaces the daemon's
  `motion_warning` when a provider-motion write fails, and stops toasting
  "assigned to everywhere Everywhere".
- `remove_effect_pack` exists on the daemon — the Studio's pack removal
  no longer answers `unknown_command` — and scene packs can be imported
  from the window. Assignment rows say what they do ("plays as Devin's
  motion while it works", "fires on done events", "the Dot follows the
  strip while linked").
- Dead call sites removed: the fire-and-forget `applyCalibration` and
  `previewCalibration` posts are gone; every calibration call awaits its
  verdict.

## 0.9.0

- Assigning an effect now does what the picker says. Provider-scope
  `provider_animation` assignments write `colors.provider_animation`, the
  persistent per-provider motion the solo renderers already read — so
  "Devin breathes while working" is a real write instead of a recorded
  wish, and clearing the assignment restores Automatic. Semantic targets
  the event router can never deliver (`working`, `idle`, `recovery`,
  `environment`, `transition`, `quota`) are refused `unroutable_semantic`
  rather than saved as a write-only row, and an assigned effect's own
  program — parameters applied — is what reaches each surface, rendered
  once per selection and compiled per LED count. The four bounded
  builtins keep their safety-timed variants.
- Settings > Remote's Serve switch runs the endpoint it describes. The
  app mints a bearer token once (`~/.local/state/jrbar/serve-token`,
  0600) and hands it to the daemon it spawns; with `serve_enabled` on the
  core hosts `serve.py` in-process on loopback and `serve_token` reports
  `running` alongside `enabled`, so the card can say serving, not just
  switched.
- The core protocol grew the commands the panel's newer affordances need.
  `dismiss_session` acknowledges a live or stuck row — the same receipt
  `clear_completed` writes — so it leaves the list until the session next
  speaks; remote rows and sessions with an open ask are refused.
  `mark_history_seen` advances the activity ledger's persistent
  `last_seen` watermark, and `list_history` now derives each row's
  `unseen` from it rather than a stored flag. `list_scene_packs`,
  `import_scene_pack` (validate-and-preview before any write, with
  version-1 packs migrated on the way in) and `preview_scene_pack` expose
  the Scene pack store to the Studio. `serve_token` hands the loopback
  status endpoint's bearer to Settings over the local socket only.
- The state document says more of the truth. Asks carry `answerable` and
  `replyable` computed from the provider's negotiated contract and the
  registered handler, so an Approve button is never offered for an ask no
  daemon can type. Sessions carry `remote` for a peer Mac's row.
  `health.detected` reports which provider CLIs were actually found, and
  `install_hooks` answers per-provider `detected` plus a refused row for
  a provider that was never seen rather than claiming success.
  `catalog_generation` lets a client reload the effect catalog only when
  it actually changed.
- The mock daemon (`app/scripts/mock-core.py`) matches: dismissal,
  remote rows, history watermarks, scene packs, detected-agent metadata
  and the serve token, so app development and fixture tests exercise the
  same contract.
- The panel says what it means. `long_task_progress` rows read Working
  instead of grey Idle while the header still counted them; failed
  sessions get their own tint and count; asks sort oldest-first and
  snoozed ones stop pulsing in the menu bar; quiet rows say quiet, remote
  rows say which Mac, and a stuck row can be dismissed in place.
  Answer-in-place only offers Approve/Deny or a reply field when the
  daemon reports the ask answerable, and a refused answer surfaces the
  refusal (with the Accessibility-settings deep link when that is the
  missing piece) instead of toasting "Approved" anyway.
- The surfaces got honest. Effect Studio's scope picker only offers
  targets that can fire, "keep tuned parameters" actually reaches the
  daemon, scene packs list/import/preview from the window, and hardware
  preview says which target it lit. History rows carry real durations,
  open affordances only appear on live sessions, and the unseen banner
  resets when the window opens. Usage Center reads the daemon's
  per-window forecast, keeps duplicate provider accounts distinct, and
  shows missing readings as missing rather than zero. Calibration errors
  surface instead of silently saving, and hardware-gated controls say so
  when nothing is plugged in.

## 0.8.1

- A Devin session could read "Working" forever. The startup replay seeds a
  compatibility status row per session from the newest legacy record and
  normalized ingest never touches it again, and the merge let that frozen
  row shadow the live canonical projection on precedence alone -- a
  `PreToolUse` replayed moments before a restart outranked every newer
  truth until the presence horizon dropped the row outright. Precedence now
  only decides between observations of the same moment: a supplemental
  status must be at least as fresh as the projection it would outrank.
- The process registry's read side learned what the write side already
  knew. Shared-host providers record the host's pid, not the session's, so
  a leftover `devin acp` record made every historical Devin session look
  alive for as long as the host stayed up -- vetoing the silence timer on
  the status row and pointing "answer in terminal" at a process that owns
  no terminal. The record's own end is still session-level truth; liveness
  is left to the silence timer.
- Every `PostToolUse` carries a derived request identity so it can close
  the ask its own tool call opened, and most calls never had one -- but
  resolving a request nobody opened materialized a permanent tombstone. A
  long session accumulated the 1000-request cap of dead entries and every
  refresh and reduce paid to carry them. Unopened resolutions are now a
  no-op, and dead tombstones are filtered on write and on restore, with the
  works' request linkage re-derived from what survived.

## 0.8.0

- Usage history answers inside a reply budget. A cold Codex scan over
  5,541 rollouts takes 45 s and the app abandons a command after 10 s, so
  the Usage window showed nothing at all. The scan now runs on its own
  thread and the reply waits at most 2 s for it; past that the reply is
  what memory holds -- `pending: true` with empty rows, or the last
  document with `stale: true` -- and a new `usage_history_ready` event
  says when the fresh one has landed. The daemon warms both providers'
  30-day scans 8 s after start. Measured over the socket: first ask
  answers pending at 2.02 s, the event lands at 2.4 s, every later ask is
  under 10 ms; Claude answers inline at 1.3 s. A provider with a price
  table but no configured account (Gemini) now answers empty rows and its
  reference quote instead of `not_found`.
- Codex ran whole turns with JR-Bar seeing nothing whenever `CODEX_HOME`
  was reached through a symlink. Codex canonicalizes the config path
  before it looks up `hooks.state."<config>:<event>:…"`, so the
  unresolved spelling produced keys it never reads -- and it then runs no
  hook at all, silently. The trust writer resolves the path.
- Pi's `ui_prompt_start`/`ui_prompt_end` do not exist. 0.73.1's
  `ExtensionEvent` union has no such names; its tool gate, `tool_call`,
  asks an extension for `{block, reason}` rather than a person, so pi has
  no ask lane and `PermissionRequest` is gone from its event set.
  `before_agent_start`, not `turn_start`, is the prompt: `turn_start`
  fires once per model turn and re-announced the prompt after every tool
  result.
- A Codex `PermissionRequest` used to hold the session's own `SessionEnd`
  behind a timing quarantine: per-record diagnostics (no request id, no
  request capability, no request authority) were reported as the *source*
  losing freshness. A request identity is now derived from the turn and
  the exact tool call when the payload names no request.
- New: `scripts/mock_llm_server.py`, a stdlib-only OpenAI/Anthropic/Gemini
  endpoint that answers every turn the same way, and
  `scripts/verify_providers_live.py`, which drives Codex, pi and Claude
  Code through real turns against it in scratch homes and asserts what the
  daemon recorded. `docs/FINAL-TESTING.md` is rewritten around the five
  0.8 gates. The supported Python floor is 3.12.
- Usage history: the transcript scan keeps the newest files when a corpus
  is over the per-source cap (now 8,192, was 4,096) instead of the first
  in path order. `~/.codex/sessions` is date-partitioned, so the old rule
  dropped exactly the current days: 5,540 rollouts on the Mac left
  `usage_history codex 7d` at 0 records and `30d` nine days short.
  Codex records now carry the turn's model from the rollout's
  `turn_context` rows (`gpt-5.6-sol`, `gpt-5.4-mini`, …), so the price
  quote is the table row for that model rather than the config default or
  the reference estimate; the Codex scan cache is rebuilt once
  (`CODEX_CACHE_SEMANTICS_VERSION` 5).
- Core protocol: the Creator Micro 2 lives in the daemon. `state.deck`
  (device, 13 slots, 7 auxiliary controls, banks, rail, keymap,
  input check, last input, settings) is projected from the session board,
  `deck-controls.json`, `integrations.json`, a background HID probe and
  the keymap backup; the `deck_press`, `deck_pin`, `deck_bank`,
  `deck_rail`, `deck_clear_absent`, `deck_plan_keymap`, `deck_apply_keymap`,
  `deck_restore_keymap`, `deck_approve_device`, `deck_check_input` and
  `deck_set_settings` commands run the existing board, dispatch and
  keymap setup code (no NSAlert headless: the plan text goes to the app);
  `deck_input` and `deck_receipt` events carry the Python app's receipt
  sentences. New 0.8 rule: a session key whose session has a live ask
  answers it through `answer_ask` when the daemon confirms the session's
  terminal is frontmost, else reveals the session. The daemon now starts
  the optional integration runtime (Creator Micro output and deck input)
  as the menu-bar app did; `hello` advertises `deck`.
- Auto-dim replaces night warmth: the `auto_dim` setting (`off` by
  default, `schedule`, `display`, `ambient`) feeds `brightness_policy`'s
  `night_dim` stage; ambient mode reads the light sensor through IOKit's
  HID event system and falls back to the display when there is none.
  `lights.auto_dim` reports `{mode, source, factor, available, reading}`
  and `why_detail.dimming` says `auto_dim`.
- Core protocol: `state.sessions[].label` is human (the provider's own
  session title, else the derived project/prompt name, else the working
  directory, else provider + short id; workers hang off their parent),
  with new `short_id` and `cwd`; `lights.surfaces.*.why` is the documented
  enum (`idle`, `working`, `waiting`, `completed`, `failed`, `capacity`,
  `quiet`, `sleep_dim`, `idle_dim`, `battery`, `calendar`, `reminder`,
  `escalation`, `preview`, `studio`, `unknown`) with `why_detail`;
  `usage.providers[].windows[].name` is `5h` / `7d` / `Daily` / `Weekly` /
  `Monthly` / `Credits`.
- A volume named `PulseDot` (first-batch Dot firmware) is a 2-LED SidePulse
  Dot with a stable identity, not an 8-LED strip.
- Pro + Dot linked mode: the new `devices_linked` setting (default on)
  writes both devices in one hardware worker command from the same
  presentation and anchor; `lights.devices_linked` and `linked_skew_ms`
  report it.
- Link mode gets honest: two mechanisms shared the word and neither told
  the truth about itself. The linked Dot used to replay an unplugged
  strip's last program forever — the inventory change now forgets it and
  the Dot falls through to its own display. With two strips the Dot
  follows the first in inventory order, the one `lights` calls
  `hardware`, and the second strip's writes no longer overwrite the
  program it loops. The Dot's surface carries the strip's anchor only
  after a coupled write actually landed, a failed linked write surfaces
  as `dot_link.state: "failed"` with its error class, and the new
  `lights.dot_link` object says which of `off`, `no_dot`, `no_strip`,
  `beacon`, `solo`, `linked` or `failed` applies, with `linked_skew_at`
  timestamping every `linked_skew_ms`. `state.devices[].linked` stops
  repeating the Screen Bar's setting on every row: the bar reports
  `link_screen_bar_to_hardware`, the pair reports whether a Pro and a Dot
  are actually joined. The Screen Bar's own link gains
  `screen_bar_phase_offset_ms` (±1 s, default 0) to nudge the bar against
  the strip, and the app reads all of it: the Dot's readout says
  "Nothing to extend" or names the failed write, a link glyph sits
  between the panel's Pro and Dot chips, and the two links are never
  conflated in copy again.
- Calibration is a guided sheet now, and its preview finally tells the
  truth. The old preview multiplied the working gains into the patch hex
  and then ran it through `preview_program`, which applied the STORED
  gains through the strip transfer on top -- at the owner's real G=0.38 a
  previewed white drove green at ~12 while the applied profile drove 97.
  The new `preview_calibration` command takes the nominal patch plus the
  working gains, resting glow and brightness and puts them through the
  same write boundary live output uses, once, and `end_calibration_preview`
  hands the device back to the live program; the hold is daemon-side
  (600 s, re-armed on every change) so the sheet's debounced edits no
  longer flash three-second previews. Brightness is part of the profile
  (`apply_calibration` accepts `brightness`, and a device dimmed by
  calibration stops reading "Uncalibrated"), a Dot can light its strip
  beside it with `companion: true` so the two can be matched by eye, the
  Screen Bar calibrates through its own code-domain transform on
  `virtual:status-bar`, and battery display mode now runs the same strip
  transfer the agent path does instead of a code-domain multiply that
  rendered every colour differently. Fixes along the way:
  `with_device_resting_glow` used to drop the glow when the device had no
  settings row yet, and a malformed calibration number answers
  `invalid_args` instead of leaking a ValueError.
- The panel now says when a quiet is in effect, and says it truthfully:
  `state.focus` carries `mode` (`pause`, `dim`, `mute`, `dark`,
  `asks_only`, or the literal `off` -- never null), `source`
  (`override` for the panel's own Quiet menu, `schedule`, `focus` for a
  macOS or named Focus) and `until` (when this quiet ends; null when
  none is in effect). The footer reads "Paused · 42m" in the waiting
  amber, a `moon.zzz` glyph sits in the header, and "End quiet" exists
  only while the quiet is the panel's own override -- a schedule's quiet
  is not this menu's to cancel. The Quiet menu's presets run in the
  chosen mode ("Until 08:00 tomorrow" names the real clock time rather
  than promising a guessed 12 h). Session rows gain a context menu --
  open in the session's own terminal, snooze the family for 15 minutes /
  an hour / until tomorrow (or Unsnooze; `sessions[].snoozed_until`
  carries the family mailbox's expiry so the row knows), copy or reveal
  the working directory, and Clear for finished, ended and stale rows --
  and the full path is the row's tooltip. ⌘↩ and ⌘D answer the selected
  ask card once, at the panel level, instead of once per row.
- Settings stops lying about usage. "Show tips" is gone (no tip UI
  exists); the Usage page's provider list is now honestly labelled "Menu
  bar meters"; "Lead with" and "Graph range" are `usage_display_mode`
  and `usage_graph_days` for real -- the Usage Center's toolbar writes
  the same keys through `set_setting` instead of a private UserDefaults
  copy, and the panel's sparklines follow the configured range (a week,
  or a month when the range is longer). A stored "percent" metric reads
  as tokens rather than rendering nothing, and the nonexistent "Today"
  range is gone from the picker. Provider colours set in Settings ›
  Lighting (`colors.agent_colors.*`) now reach the panel's rows and
  sparklines, the Usage Center's tiles and rings, History's tiles and
  filter chips, and the menu-bar meter columns.
- New providers: pi (`jrbar agent-monitor install pi` writes
  `~/.pi/agent/extensions/jrbar.ts`) and Gemini CLI (`install gemini` adds
  hooks to `~/.gemini/settings.json`), both with transcript fallbacks
  (`transcript_monitoring.pi` / `.gemini`), lifecycle rules, colours that
  survive dichromacy, and fixtures. The shim prints `{}` for Gemini (and
  with `--emit-empty-json`); the hook doctor reads folded YAML, embedded
  argv arrays and the Antigravity envelope; OpenClaw and OpenCode accept
  the shim argv; `scripts/install-agents.sh` re-points every provider at
  the installed shim.

- Rename the software from SidePulse to JR-Bar. The Python package is `jrbar`
  (`sidepulse.*` imports and `python -m sidepulse.hook_client` keep working
  through a one-release shim), the CLI is `jrbar` (`sidepulse` stays as an
  alias for one release), the app is `JR-Bar.app` / `com.jonathanreed.jrbar`,
  the LaunchAgents are `com.jonathanreed.jrbar.app` and
  `com.jonathanreed.jrbar.sdejectguard`, config/state/data live flat under
  `~/.config/jrbar`, `~/.local/state/jrbar` and `~/.local/share/jrbar`,
  environment variables are `JRBAR_*` (the `SIDEPULSE_*` names are read as a
  fallback), provider Keychain items move to `com.jonathanreed.jrbar.provider.*`
  with copy-forward on read, and every provider hook installer replaces its
  pre-rename registration instead of duplicating it. First launch and
  `jrbar setup` copy an existing SidePulse install forward automatically;
  the hardware names (SidePulse Pro, SidePulse Dot) are unchanged.

- Remove night warmth and the 7 PM–7 AM night dim (the Night Warmth card,
  `NIGHT_WARMTH_GAINS`, and the `night_warmth_enabled` / `night_dim_fraction`
  settings, ignored on load). `brightness_policy` keeps its `night_factor`
  input, fed 1.0 until a time/ambient-light auto-dim replaces it.
- Remove the operator history/diagnostics JSON export (`operator_export`, the
  Local Export card and its two buttons). Operator history itself stays.
- Remove the timebox/timer: the Timer menu, presets, Focus-handshake
  Shortcuts, the "Working timer fill" device display and its
  `timer_fill_program`, the timebox webhook event and chime, and the
  `timer_expected_minutes` / `timebox_shortcuts` settings (ignored on load).
- Remove severe-weather alerts: the NWS/ipapi fetchers, the weather signal,
  style card, Today row, webhook event, demo scenario, and settings. Old
  `weather_*` settings keys are ignored on load. `QUIET_HOUR_EXEMPT_KINDS`
  is now empty.
- Remove the `sidepulse-waybar` client and its console script; `sidepulse serve`
  keeps the loopback status API.
- Remove the external Agent Deck snapshot compatibility (`agent_deck_compat`,
  the `agent-deck` integration, and its ownership yield). The built-in deck
  modules remain as the Creator Micro Control Center.
- Remove the iOS companion app and its Mac half: the `sidepulse glance`
  private listener, `serve --phone-glance`, and the `/glance.json` route.
- Consolidate historical feature/fix branch ancestry without overwriting newer
  implementations; preserve the unmerged historical plan under `docs/archive/`.
- Fix overlapping session-board saves, drain persistence on shutdown and persist
  compact-rail edge selection with backwards-compatible board settings migration.
- Fence bank changes and virtual-input confirmation against stale queued actions;
  refuse new input during termination and reap terminated Shortcut subprocesses.
- Require pending keymap recovery to resolve before a new apply; verify an intact
  original without writing it again.
- Add `make final-test` for clean-checkout, pinned Mac source/package verification
  with local logs, exact source identity and JUnit output; repair portable fixtures
  and include control-center regressions in the ordinary gates.

- Add a hardware-optional native Control Center with stable, identity-scoped
  session slots, explicit banks/pins, input checking and a compact four-edge rail.
- Complete the reviewed HID framing/nonblocking/write-result fixes; classify
  method-tagged firmware errors and retain Python 3.10 Creator Micro imports.
- Add bounded binary keymap reads/writes, device checksums, scratch-file preflight,
  private first-original backup and generation-bound interrupted-write recovery.
- Add selected profile/layer and supported auxiliary-key previews, analog joystick
  sectors, mapping import/export, per-session lighting and stock-map aggregate preview.
- Keep distinct user inputs in a bounded ordered queue, revoke stale generations,
  and expose explicit named macOS Shortcuts without a shell/device execution channel.
- Refresh T3 read-only projection compatibility, keep native and T3 identities
  distinct, and require explicit turn outcomes instead of treating idle as success.
- Portable regression checks do not certify native hardware or a release. Required
  final Mac/device/provider/release checks are in `docs/FINAL-TESTING.md`.

## 0.6.0

- JR-Bar now presents provider attention, activity, authoritative quota limits,
  account aliases, privacy-safe menu rows, reset delivery receipts, and local
  usage heatmaps through one command-center model. T3 Code and Agent Deck
  compatibility are read-only. Creator Micro 2 output uses an approved-device
  identity boundary and yields device ownership to Agent Deck when configured.
  Provider exhaustion can release a stale keep-awake claim without pretending
  that the agent process stopped.
- Screen Bar glow layers now use native Core Graphics gradients instead of
  hundreds of Python-to-Quartz rectangle fills per frame. Continuous ambient
  sampling uses the same bounded cadence as the display surface while finite
  alerts keep their responsive cadence.
- macOS packaging now delegates PKG assembly to an executable, testable
  standard-library seam with fixed production tool paths, explicit missing-tool
  failures, signed and unsigned command coverage, and clear certificate-error
  reporting. The builder validates the full source/package/changelog version
  contract before work starts. The release gate rebuilds the exact wheel and
  source distribution in an empty staging directory, validates both with
  Twine, and binds them to the release evidence. Release checksums are generated
  atomically in deterministic root-relative order and publication refuses any
  asset changed after that evidence was written.
- Production bundles now embed digest-pinned Sparkle 2.9.6 with exact nested
  signing checks, a visible Software Update submenu, stable and beta channel
  selection, and consent-owned automatic checks. The release gate creates a
  supplemental ZIP from the notarized and stapled app, signs and verifies the
  appcast with the dedicated Keychain key, binds channel metadata and receipts
  to the exact candidate, rejects non-monotonic upgrades, and publishes the
  immutable version archive before changing the durable feed. No release or
  feed was published by this source work.
- `make fast` now provides a fail-fast ordinary-change gate over Ruff, real
  imports, lightweight contracts, tracked-file secret scanning, literal
  fixtures, 430 selected contract, fixture, and semantic tests, compilation,
  dependency and version
  policy, and diff hygiene. Full-suite, build, installed-app, hardware, signing,
  notarization, Instruments, and release evidence remain separate. The signed
  release source receipt now disables build and clean-install work so it cannot
  delete the exact candidate or evidence directory it is validating.
- Why Is It Doing That now includes a fixed Current light context section with
  the selected semantic and P1-P7 priority, oldest visible source age, bounded
  current finite-cue suppressions, Scene availability, global surface role,
  Focus/DND observation-policy-decision, Reduce Motion substitution, and
  source-labeled active-output timing. Screen Bar renderer callbacks and
  physical hardware-write latency remain distinct, unavailable values stay
  explicit, and live refresh preserves selection and scroll position without
  retaining prompts, transcripts, identifiers, or a second telemetry store.
- Native notification access now fails closed outside the sealed application
  bundle. Authorization refresh constructs its bridge on the main thread, so
  source tests and unbundled Python processes cannot invoke Notification Center
  through an invalid application identity.
- The explanation panel now shows nine fixed, content-free health aggregates
  for the current run: render duty cycle, dropped batches, delivered FPS,
  runtime queue depth, physical write latency, source freshness, worker count,
  shutdown latency, and refresh duration. The projection reuses existing
  bounded in-memory owners, renders missing observations as unavailable, and
  is never persisted, exported, or sent to a cloud service.
- Power settings now separate the ordinary agent system hold, optional display
  assertion, battery continuation, and stronger closed-lid policy. Displays may
  sleep by default while agent work continues. Changing the display choice
  replaces only the stale `caffeinate` child and preserves battery, grace,
  helper, watchdog, and renewal state.
- Provider hooks now submit to one private, bounded, ordered app-owned ingress
  queue. Accepted work retains FIFO order through the canonical minimizer,
  dedupe, private write, and refresh path; overload and shutdown timeout produce
  content-free receipts; unavailable ingress falls back to the same synchronous
  processor. OpenCode and OpenClaw now await tracked client admission instead
  of detaching unobserved children. A reproducible source benchmark reports
  listener and fallback latency without retaining event content. App-owned
  refresh reconciliation completes inside the ordered worker, so normal shutdown
  does not persist latest state ahead of the accepted tail.
- Screen Bar prefetch now stays inside one generation, parsed program, and
  cadence. New commands and timing stalls discard stale frames immediately,
  finite cues stop requesting frames beyond their visual deadline, and local
  profile counters separate shortened or invalidated work from renderer
  fallback.
- Usage Center, usage-menu, and settings-summary repaints now consume one
  immutable worker-produced state and settings payload. Cross-Mac merge evidence
  is refreshed before AppKit dispatch and reused by logical snapshot value, so
  steady-state UI refresh no longer reads provider settings, Keychain
  credentials, or cached packet files.
- Usage-percent, provider-reset, operator-history, and capacity-history writes
  now share one bounded serial persistence owner. Ordered appends advance their
  watermarks only after a successful receipt, replaceable snapshots keep FIFO
  position honest, capacity consent deletion fences stale queued flushes, and
  normal shutdown reserves one final tail slot before draining accepted work.
- Physical LED writes now coalesce by opaque semantic slot instead of replacing
  every pending command for a device. Asks, failures, finite cues, and explicit
  calibration previews outrank obsolete ambient frames while the latest normal
  state remains queued as the trailing edge. Saturation evicts lower-priority
  work, selected display kinds are snapshotted before worker dispatch, and lid
  flourishes refuse to race a writer that cannot become idle.

## 0.5.0 — Coalescence

The name is **JR-Bar** now (display-name-first; bundle ids stay `io.sidepulse`). Fully divergent from upstream by decision, not drift.

### One system, ~12,000 fewer lines

- Seven audit lanes reported; everything they proved dead is gone in ratchet-safe order: the delivery-planning plane nothing ever invoked (planner, quiet plane, delivery ledger — the canonical-runtime fixture is honestly ten steps now), `runtime_truth` (the KNOWN_UNWIRED ledger reached its goal state: empty), the runtime-install transaction, the quota-forecast plane (owner sign-off; the JR-plane quota runway already answered its question), the replaced Screen Bar draw bodies, the no-op status-audit plane (its residue file is janitor-cleaned from installs), the mailbox v1 writer + migration resolver (store-security tests ported to the v2 API, which proved *stricter* under a parent-swap attack), the pre-mailbox session-menu formatting cluster, the dead `sync_leds_now` render ladder (its tests now drive the live request/worker pipeline and came out stronger), AgentLayoutStabilizer, DeferredMenuPublication, and ~23 leaf orphans whose live claims became test-local oracles.
- The settings_window injection ratchet's retired-branch was a tautology; it bites now, and the injected-name set shrank 60 → 30 (every name importable without a cycle is a real import).
- The two capacity planes stopped double-polling Claude's endpoint (the 429 mechanism); the JR plane owns capacity and the usage menu row outright.

### Wired, not shelved (owner calls)

- **Snooze Until Tomorrow means tomorrow morning** — 9 AM local via the store's timezone-correct resolver, not a flat 86,400 s that missed the morning and drifted across DST.
- **Triage acknowledgements prune** on terminal request truth; the store previously never shrank.
- **Hook registration probe-runs the command before writing it** — a hook that cannot run never reaches an agent config (the failure mode was every prompt in every session blocked).
- **The Agent Browser answers its keyboard**: Return opens, Escape closes, ⌘F finds, arrows move.
- **A hidden main menu** makes ⌘C/⌘V/⌘W/⌘Z/⌘Q work in every window the app owns.

### Native feel

- The dropdown stops rebuilding on a timer: the 30-second signature valve (a measured 799 ms average AppKit rebuild, forever) is deleted; identical content now hashes identically across time, pinned by test.
- The legacy usage card is never built-and-discarded per rebuild.
- Polls, EventKit fetches, and 30 fps settings previews defer past scroll gestures (default run-loop mode); the lights' own deadlines deliberately stay live mid-scroll.
- Settings panes crossfade and their cards cascade in (20 ms stagger, layer transforms only; Reduce Motion keeps the plain fade).

### The Apple-magic layer (motion language, measured from Apple's own work)

- **Idle breathes like a Mac asleep**: the asymmetric human-rate curve (inhale 1.9 s, exhale 2.55 s, dark dwell 850 ms, ~11/min — patent US6658577B2's rate, the measured MacBook curve's shape) replaces the 6 s symmetric pulse; the solo breathe drops from an anxious 18.75/min to the same curve.
- **Urgency arrives as one overshoot-and-settle crest** (swell 300 ms, settle to a 55% hold, anchor stands up) — never two square taps, never a repeated flash.
- **Done crests**: the completion bloom overshoots to 112% luminance once before basking.
- **Plug-in says hello in mint** (rise LED-by-LED, one crest, then the steady fill) and **device connect plays first light** (one soft white breath, then identity). INIT.LED remains the user's own power-up look.
- **The announcer pill arrives on a spring** from its top anchor and fades out faster than it faded in; Reduce Motion keeps the instant show.
- **The refill tells its story**: reset celebrations are the refilled provider's own color rising like a gauge, one white crest, two sparkles — not generic confetti.

### Flows

- **Calibration is a guided stepper**: "Does the light look white to you?" with one-tap Too warm / Looks white / Too cool nudges; fine RGB sliders hide behind Fine-tune; Compare-with-before is one button.
- **The Studio builds without typing**: rows of color wells, duration dials, and feels compile live into the editor through the same validator, persist, firmware parse, and preview. The DSL is an output format now.

### Docs

- FEATURE-MATRIX rewritten from live source (Kiro restored, a 0.3.0-dead bridge row removed); five stale plan documents archived; README renamed and corrected (no Gemini, no notification DB, honest install story); the Signal API plan retired.

### Deliberately deferred, with designs on file

Async settings saves (88 call sites need a debounce plus termination flush), the Screen Bar's ask-swell geometry spring and the 100 ms screen→strip event ripple, VoiceOver row descriptions (needs a view-based table first), and a real consent gate for the activity ledger (its old toggle was a lie and is gone).


## 0.4.0

### Owner decisions, implemented (audit wave 3)

- **Motions are real everywhere.** Cycle turns render each agent's chosen rhythm on the whole strip (byte-budget aware — agents degrade from the end back to the classic breath only when the firmware's 512-byte cap demands it; Automatic keeps Cycle's classic breath exactly). Spatial Split blocks honor the full vocabulary with intra-block travel (converge fronts meet mid-block). In shared strips the positional classes are finally distinguishable — narrow flare (scanner/KITT/comet/marquee/gradient) vs full swell (chase/tide/converge) vs hard pile-on (stack) — and aurora is no longer byte-identical to drift. Relay's collapse is physics (a ~350 ms flare can't hold a lub-dub under the 2 Hz law) and the motion descriptions now say what actually happens.
- **What you preview is what plays.** Thumbnails, hover try-outs, and the hardware preview push all route through the real solo renderer — hovering Knight Rider plays the KITT eye, not a generic roll.
- **Solo honors your gentleness sliders** (fade floor/ceiling), so one working agent is no brighter than the same agent in a crowd; the motion picker still outranks the classic style. **Urgent states keep a guaranteed minimum swing** — an Ask can never become an unblinking steady light, whatever the sliders say.
- **Quota Runway lives**: the LED display is selectable again and fed from the JR usage plane's own gated lanes (worst remaining lane, provider-colored) — the same numbers the menu meters trust.
- **Honest economics**: Fable 5 priced at its published $10/$50 rates, Codex priced from its GPT models (post-Aug-22 Sol cut), and every dollar figure discloses "NN% of tokens priced" whenever coverage is partial.
- **Cross-Mac sync reaches the Usage Center** ("N tokens across synced Macs" renders from locally cached, signature-verified peer documents — never a network fetch in the window path), replay gets a 7-day freshness window, and the docs stop claiming encryption: packets are HMAC-SHA256-signed JSON riding SSH.
- **Snooze means quiet**: a snoozed session stops claiming the LEDs and stops notifying; a genuine ask still breaks through everywhere, and the Agent Browser deliberately keeps showing everything.

### The test suite keeps its hands off the desktop

- Running the tests used to make the machine unusable: AppKit tests exercised product paths calling `makeKeyAndOrderFront_` / `activateIgnoringOtherApps_(True)`, yanking focus from the owner repeatedly for the whole run. Two independent fixes: conftest sets the PROHIBITED activation policy at import time (macOS itself refuses to ever activate the test process), and all twelve window-presentation sites now route through one gate (`window_presentation.py`) that no-ops in the test sandbox. A source ratchet fails the build if anyone writes a direct takeover call again; tests that verify presentation behavior opt back in against mock windows.

### Reset confetti & the alert layer, resurrected (feature audit wave 2)

- A refilled rate limit finally celebrates: multicolor confetti sweeps the bar (finite, safety-compiled, self-terminating on the device) plus one 🎉 notification per event — gated by the courtesy budget, deliberately NOT by the alerts switch. Detection now also fires on a ≥50-point replenishment jump, so a failed poll re-stamping the clocks can no longer hide a reset (exactly how today's live reset went unseen).
- `quota_alerts_enabled` was hard-wired False in three places with no switch, and four alert features routed their only surface through it — reset blink, pace notifications, threshold effects, connection cues. The flag is real now, with a switch in Settings → Extras; pace alerts and the quota blink work for the first time. The legacy raw-percent tracker stays a stub: effects fire on the JR plane's own snapshot transitions, never raw percentages.
- Connection-loss cues actually render (a brief amber notice blink via the notification program that shipped with no claim), and losses hidden inside stale-served snapshots are now detected.
- The sessions chart covers the whole fleet: grok, devin, and every hook-emitting provider chart their per-day sessions from the agent-monitor ledgers alongside Claude/Codex transcripts. "Percent left" mode survives restart, provider selections persist beyond the old two-provider filter, and days before history began render as gaps instead of a fabricated flat line.
- Edge detectors can no longer be blinded by a refresh tick landing mid-apply (resets, thresholds, pace, hooks, and connection losses all diffed against a baseline only the apply path owns).
- Screen Bar: the sampler's hard-coded alpha made dark LEDs opaque black — killing the min-glow floor, the identity collapse, and painting a ~92%-opaque black band on notchless displays; alpha now carries "how lit." The bar also no longer re-runs its full show/reposition dance on every tick while the display sleeps.
- Firmware-reboot detection had never fired in the shipped app (it read `LEDS.LED/STATUS.TXT`); the timebox chime could never play (courtesy grants hard-coded silent); the stage-3 escalation webhook never fired at the default tier (the tier capped the stage before the check); the Studio silently lost typed-but-unpreviewed programs and captures; the Usage pane's status line imported a function that didn't exist; the Devices pane stopped rebuilding on hot-plug under the category navigation; Cursor's reconnect loop could never succeed (stale app-database token always outranked the freshly pasted one); antigravity and openai-api action buttons did nothing; devin's daily lane could hit 0% with no pace verdict possible. All fixed, plus a batch of settings controls that went stale after external changes.

### Reconnect that tells the truth

- Automatic recovery: a signed-out provider stops being re-asked every two minutes and instead watches its own credential file (`~/.grok/auth.json`, `~/.codex/auth.json`, `~/.claude/.credentials.json`) — the moment `grok login` (or any sign-in) rewrites it, the next refresh retries immediately. Transient failures ride an exponential ladder (5 min → 1 h) instead of hammering; a 429 from the Claude usage endpoint now backs off instead of guaranteeing the next 429.
- Reconnect Grok actually probes: it reads the CLI's auth file, clears the stored-token wedge that could shadow it forever, and reports what it found — including "already signed in as you" when the old button would have said `run grok login` to a signed-in user.
- Connect Claude can no longer claim success with a dead token: expiry and the signed-out-with-refresh-token shape are checked before "connected" is allowed, and each failure names its fix.
- Codex gets a real action: the honest report of the newest completed session's age, with the instruction that a turn must *finish* (opening and quitting Codex writes nothing). Stale copy now says "finish one Codex prompt to refresh." A scan that finds no quota evidence no longer silently erases the last real reading.
- Every reconnect message lands somewhere visible by construction — the Usage Center opens with the banner already set; nothing answers into the void. A user-forced refresh no longer piggybacks on an in-flight run that read the old credential. A provider dropping from healthy earns one attention cue through the normal interrupt gates.

### Effects

- Four new motions, all sourced: **Knight Rider** (upstream PR #29's KITT eye — wide overlapping pulses sweeping out and back), **Gradient** (tlip's rolling wave where each LED carries its own shade), **Marquee** (a palette seeded from the provider color, rotated by the firmware's own roll), and **Duotone** (the iOS pattern library's two-tone breathe). All pass the safety compiler and the real firmware grammar on 2- and 8-LED builds.
- Settings thumbnails no longer preview every travelling shape as a plain pulse: the motion→style bridge now covers the whole vocabulary, so scanner/comet/KITT-class motions read as motion in the aggregate renderer too.

### Ambient

- Charging trickle while idle (on by default, one switch in Battery settings): plugged in with nothing running, the bar fills to the charge level in mint with the wattage-paced trickle pulse — and running, asking, freshly-done, or failed agents always take the strip back. Dims like furniture with the ambient stack instead of flashing at signal brightness. Pulse length is bucketed so adapter-wattage jitter no longer rewrites the device's flash every refresh tick.
- The bar stays alive with the lid closed: hardware writes are no longer gated on display sleep (the strip is an external light on the side of the machine), and lid observation no longer stops at exactly the moment the lid closes.
- Night brightness: an optional 7 PM–7 AM dim (50/30/15%) beside Night Warmth, composed into the same stack as idle and Focus dimming; escalation ramps still push through.
- A Sleep Focus with no explicit rule now defaults to near-off instead of the shared dim.

### Studio

- Typing lag: validation is debounced to one parse per pause instead of one per keystroke, and the per-keystroke device enumeration behind the LED-count check is cached.

### Overview chart & app-wide lag (post-deploy audit)

- The Overview usage chart no longer shows "No activity in this range" while it is actually scanning: the view is seeded with a real "Scanning local activity…" state (the worker's placeholder could never reach a freshly built pane — settings_fields is assigned only after the builder returns), a range change mid-scan is remembered and re-fired instead of silently dropped, and identical inputs within a minute are served from memory instead of re-paying the scan.
- The transcript scan thread (30 s cold, ~9 s warm for a year of history — six figures of JSONL lines, pure GIL time) now runs at utility QoS like the Screen Bar sampler, so the whole app stops feeling laggy while the chart loads. First test coverage for the worker.
- Claude's usage fetch timeout drops 30 s → 10 s: the one live hang left "Last known value" on screen for half a minute after Reconnect had already said "refreshing now".
- Stale lanes whose reset moment has passed say "reset passed — reading is older" instead of chanting "resetting now" forever.

### Hostile-review fixes (same audit)

- The charging trickle no longer hijacks devices pinned to Studio, Timer, Battery, or Quota Runway, and yields to a running timebox: the claim moved to dead last before the agent default and only fires on default-display devices.
- A forced refresh landing while the worker was delivering callbacks was silently swallowed, with its flags leaking into a spurious forced run minutes later — the worker now retires under the lock, so a mid-delivery click starts a fresh run.
- Clicking a non-connect Claude action ("Retry later") no longer runs the synchronous Keychain read on the main thread — only Connect/Reconnect clicks do. The Usage Center's fallback refresh is scoped to the clicked provider instead of force-marching the whole fleet through their backoff gates.
- Marquee's loop repaint carries explicit timing, so the safety compiler no longer stamps a freeze-snap hold into "endlessly rotating."
- Re-enabling a disabled provider probes fresh instead of serving its pre-disable failure for up to an hour; device inventory keeps running while the display sleeps (writes without re-enumeration raced devices that unmount during the sleep transition); the "show battery on plug/unplug" toggle got back the immediate refresh an edit splice had orphaned; the night-dim popup re-syncs on settings refresh.

## 0.3.0

### Truth model

- ACTIVE means heard from: a session silent past 240 seconds leaves the title, mailbox, lights, and rows together, and reappears on its next real event.
- Done is a moment: a completed session settles from the done green back to the idle whisper after 120 seconds instead of holding it until the presence horizon dropped the row.
- Sleep-aware clock continuity (naps are continuous; only backwards motion quarantines), boot identity from kern.boottime, live-source-elected global continuity, and per-source clock timing that round-trips through the v2 snapshot with healing for documents from the broken window.

### Screen Bar

- Classic mode is contained: opaque black housing traced from the measured per-row notch silhouette, glow feathered to housing-black before the corner fillets, rim clipped to the body, standing gauges tucked inside — nothing paints on the menu bar's own background. Wings remain the Alcove bracket's language.
- Bar and strip share one clock: the bar re-anchors to the hardware write moment, risers breathe on a six-second swell, and the strip runs the 1400 ms rolling pulse with 170 ms stagger.

### Usage

- Claude usage connects and reports real numbers (the OAuth parser now reads the endpoint's own utilization field), and the Usage Center window survives its own close button instead of crashing the app.
- Codebar-style limits: an eight-cell meter per rate-limit lane with percent left and reset countdown, amber past the provider's low-remaining threshold, in both the menu and the Usage Center.
- Menu curation: choose which elements each row shows and which providers get a row at all; the tightest visible limit rides next to the menu-bar icon on its own switch.
- Pace: every lane with a known window is judged against uniform spend — surplus, on pace, spending fast, or "runs out in ~2h 10m at this rate" when the projection lands before the reset. The menu-bar percent belongs to the provider actually running (lowest among several), on whichever window is most at risk, and turns amber when spending fast and red when it will not make the reset.

### Power

- Keep-awake holds the machine only while agents work, plus one five-minute grace window armed when work stops — rest-to-rest flapping can no longer re-arm it — and uses caffeinate -ims so the display sleeps normally.

### Ratifications and repairs (final-sweep audit)

- A failed tool call is non-terminal everywhere: the canonical adapter now agrees with the mode map and attention layer that PostToolUseFailure keeps the work ACTIVE (it filed live sessions under "ready for review").
- The dropdown's session dots and the completion celebration use provider-brand identity colors like every other surface — no more "purple for some reason when Claude's running" in the menu.
- Provider pins for every registered provider now survive relaunch (the loader silently dropped everything but claude/codex).
- Transcript replay no longer re-stamps unparseable rows with rebuild time; a bad row inherits its neighbor's stamp, seeded from the file's mtime, so stale accounting can age it out.
- The Screen Bar quota ember is real: with gauges enabled, the left tip brightens as the tightest visible lane sinks below its provider's threshold.

### Menu and platform

- "Remove Screen Bar" lives inside the Screen Bar's own submenu; only "Add Screen Bar" appears at the top level, and only while there is none.
- Global brightness control (Dim/Half/Full) for both surfaces from the menu bar.
- Builds install the wheel with --no-cache-dir so a rebuild can never silently ship a stale wheel cached under the same version.
- The test harness pins Focus state, Low Power Mode, and render environment so the gate no longer depends on the machine's battery or Do Not Disturb.

### Runtime truth and safety

- Added explicit states for not configured, reload required, awaiting first activity, idle, working, needs input, completed, failed, and stale hook sources.
- Kept `SessionStart` as session presence rather than working activity, and added specific Grok guidance when hooks were installed after the current session began.
- Added cross-process hook-event deduplication so repeated native events are written and published once.
- Separated foreground, LaunchAgent, socket-owner, and conflict process states.
- Established collection-time test isolation for HOME, XDG paths, launchd mutations, and real `/Volumes` writes.
- Collapsed the public status-bar facade so only one PyObjC controller subclass remains.

### Devices and menu

- Replaced mount-path identity with a stable hardware key derived from a hashed serial, volume UUID, or disk identifier.
- Added bounded background `diskutil` inventory so AppKit reads only cached device metadata.
- Merge remounts, prune temporary and duplicate remembered devices, and preserve device-specific brightness, calibration, provider pins, and resting glow.
- Normalized product labels so a SidePulse Dot can never become “SidePulse Dot Dot.”
- Grouped physical devices, profiles, and timers under one compact Devices submenu.
- Wrapped provider capacity under one Usage row, removed the permanent Tip row, renamed the explanation panel to Diagnostics, and hide Setup after a healthy completed setup.
- Added bounded actionable warning rows for disconnected or silent agent intake.

### Native provider usage

- Added first-party accounting for ChatGPT/Codex, Claude, Cursor, Devin, Grok, Antigravity, and optional OpenAI API organization usage.
- Added actionable source-health states, explicit provider setup and refresh commands, dynamic model- and feature-scoped quota lanes, exact reset countdowns, and finite deduplicated reset celebrations.
- Added token and model counts, credits, incidents, estimated pricing, cache-savings estimates, and cross-Mac totals.
- Added provider-scoped browser consent and isolated browser-store import, with secrets stored in macOS Keychain.
- Added HMAC-signed (not encrypted; transport privacy comes from SSH/SFTP) cross-Mac usage sync that freshness-selects account quotas, rejects packets stamped outside a bounded replay window, and deduplicates machine-local usage events.
- Wired native usage into Finder launch, packaged and source-checkout LaunchAgents, foreground development mode, the menu, and Usage Center.

### Settings and Screen Bar

- Consolidated the Settings sidebar into Overview, Agents & Providers, Usage, Devices & Screen Bar, Appearance & Motion, Notifications & Focus, and Advanced & Diagnostics.
- Kept the tested retained panes as child pages rather than duplicating their controls or creating another controller layer.
- Added a native Usage page with direct Usage Center and refresh actions.
- Replaced the hairline/full-width Screen Bar treatments with a centered, rounded 6-point luminous band bounded to 180–420 points on wide surfaces.
- Kept connected-but-silent visible as a dim outline, preserved production animation colors, and made Alcove corner brackets an explicit style instead of an automatic side effect.
- Removed temporary repository write-probe documents and migrated retired CodexBar settings out of the integration document.

### Production hardening

- Moved routine battery collection, transcript discovery, provider probing, ledger publication, and webhook delivery behind bounded background services.
- Added typed refresh admission and in-process performance diagnostics while retaining the historical AppKit controller as a compatibility host.
- Added one presentation-safety compiler for visible LED output and exact final-byte validation through the packaged firmware parser before physical writes.
- Made device settings persistence lossless and settings documents versioned, downgrade-safe, concurrency-aware, and preserving of unknown fields.
- Added a payload-only macOS package transaction, inside-out signing checks, uninstall support, dependency constraints, SBOM generation, release manifests, and an authoritative signed macOS release gate.
- Added repository governance, dependency review, self-hosted macOS verification, and architecture ratchets that prevent the retained monoliths from growing.

### External compatibility

- T3 Code remains the only optional external agent integration. It reads a query-only local SQLite projection and does not mutate T3 or read its credentials.
- Alcove remains the optional visual geometry integration for Screen Bar following.
- Removed the accidental CodexBar client, process supervisor, dashboard protocol, commands, settings surface, compatibility entry, and package tests. CodexBar is now only an engineering reference for native SidePulse provider accounting.
- Kept T3 pull-request metadata and mutation actions explicitly out of current claims because the reviewed local projection does not expose them.

## 0.2.2

- Added the JR fork’s agent status, Screen Bar, signal, quota, history, device, and macOS integration work.
- Preserved the upstream SidePulse CLI, LED format, battery tools, and device behavior.
