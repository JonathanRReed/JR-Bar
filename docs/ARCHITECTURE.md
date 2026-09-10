# JR-Bar architecture (0.8)

Three processes, one direction of truth. Read this before touching the
daemon boundary, the hook path or packaging. The wire contract itself is
[CORE-PROTOCOL.md](CORE-PROTOCOL.md); the Swift side in detail is
[app/README.md](../app/README.md); the bundle layout and signing are
[packaging/README.md](../packaging/README.md).

## The three processes

```text
 claude / codex / gemini / pi / …          (each provider's hook config)
        │ spawns per hook event
        ▼
 jrbar-hook  (C, ~3 ms)  ──frame──▶  ~/.local/state/jrbar/hook-ingress.sock
                         (no daemon: append to <provider>.pending.jsonl)
                                            │
                                            ▼
 jrbar-core core  (Python, headless)  ◀──NDJSON──▶  JR-Bar.app  (Swift)
   owns every fact                    core.sock       owns every pixel
   hooks, sessions, usage, devices,                   status item, panel, Screen Bar,
   escalation, power, peers, ingest                   Settings, Usage Center, Effect
                                                      Studio, Control Center, History,
   writes LEDS.LED to the Pro and Dot                 notifications, sounds, Sparkle
```

- **JR-Bar.app** (`app/`, SwiftPM, macOS 26+) is an `LSUIElement` accessory
  app. It spawns `Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core core`
  as a supervised child (`CoreSupervisor`: restart with backoff, "Core
  crashed" after 10 exits in 2 minutes, SIGTERM then SIGKILL on quit),
  connects to `core.sock`, replaces its model wholesale on every `state`
  frame, and sends `command` frames for everything the user does. It never
  computes a fact it could ask the daemon for; the few things it owns
  locally are listed at the end of this file.
- **jrbar-core** (`src/jrbar`, frozen by PyInstaller into the nested
  helper bundle) is the pre-0.8 controller run without a UI:
  `python -m jrbar core` in a checkout. It listens on `core.sock` (mode
  0600, peer UID checked, 4 clients, 1 MiB frames), refreshes on a 15 s
  timer plus every hook event, and pushes `state` / `lights` / `settings`
  documents coalesced to 20 / 30 / 10 per second. It exits on its own when
  its supervisor is gone (`JRBAR_SUPERVISED=1`), and on any exit writes
  `off` to every mounted strip so a quit never leaves a loop running.
- **jrbar-hook** (`hook/jrbar-hook.c`) is what every provider config
  actually runs. It reads stdin, sends one frame to the ingress socket,
  waits at most 200 ms for a disposition and exits 0. With no daemon
  listening it appends the payload to `<provider>.pending.jsonl` and the
  daemon drains that file at start and every 30 s. Whole run capped at
  250 ms; measured 6 ms wall per spawn, of which the shim's own work is
  about 3 ms (the old Python hook client took 88 ms).

Session truth is the daemon's, built from four sources that agree or
disagree in the open: hook events (with the hook's `ppid` and process
start time), the process registry and a 5 s liveness sweep (a dead pid
ends its session within seconds), Claude's `~/.claude/sessions/<pid>.json`
status files, and transcript tails for providers whose hooks say too
little (Codex rollouts, pi and Gemini session logs). A session the daemon
cannot confirm is `stale`, shown as such, never silently dropped.

## Data on disk

| Path | Owner | What |
| --- | --- | --- |
| `~/.config/jrbar/agent-monitor.json` | daemon | settings (`AgentMonitorSettings`; every key the app edits goes through `set_setting`) |
| `~/.config/jrbar/integrations.json` | daemon | T3 Code and other optional integrations |
| `~/.config/jrbar/deck-controls.json` | daemon | Creator Micro 2 bindings and board settings |
| `~/.config/jrbar/effect-assignments.json` (+ sidecar) | daemon | Effect Studio assignments, active scene |
| `~/.config/jrbar/effect-packs/` | daemon | installed data-only effect packs |
| `~/.local/state/jrbar/core.sock` | daemon | the app ↔ daemon socket |
| `~/.local/state/jrbar/hook-ingress.sock` | daemon | the shim ↔ daemon socket |
| `~/.local/state/jrbar/<provider>.pending.jsonl` | shim | hook payloads queued while no daemon listened |
| `~/.local/state/jrbar/latest.json` | daemon | the last projected state (the app's offline fallback for the icon) |
| `~/.local/state/jrbar/screen-bar.led` | daemon | the Screen Bar program as a file (fallback feed when the socket is down) |
| `~/.local/state/jrbar/usage-samples.json` | daemon | `(at, used_pct)` samples per provider window for the forecast |
| `~/.local/state/jrbar/app-state.json` | app | hooks-installed stamp, login-item marker, Screen Bar flag |
| `~/.local/state/jrbar/*.log`, `hook-records/` | daemon | logs and hook records |
| `~/.local/state/jrbar/cloud-ingest.token` | daemon | bearer token for the loopback ingest listener |
| `~/.local/share/jrbar/` | daemon | operator history, capacity history, activity ledger (each behind its own retention consent) |
| `~/Library/Application Support/JR-Bar/` | daemon | provider credential caches; secrets themselves live in the Keychain under `com.jonathanreed.jrbar.provider.<id>` |
| `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.gemini/settings.json`, `~/.pi/agent/extensions/jrbar.ts`, … | providers | hook registrations JR-Bar writes and recognises (`install.py`) |

`XDG_CONFIG_HOME` / `XDG_STATE_HOME` move the first two trees;
`JRBAR_STATE_DIR` moves the sockets for tests. Pre-rename SidePulse trees
are copied forward once by `migration.py` on first launch and recorded in
`~/.local/state/jrbar/migrated-from-sidepulse.json`.

## What runs when

| Moment | What happens |
| --- | --- |
| Login | `SMAppService` launches `JR-Bar.app` (registered on first launch; Settings › General turns it off). |
| App launch | The app reads `app-state.json`, spawns the daemon, shows the status item, restores the Screen Bar if it was on. On the first launch of a build it runs `jrbar-core agent-monitor install all` so every provider with a config on the Mac runs the bundled shim, then registers the login item. |
| Daemon start | Loads settings, migrates from SidePulse if needed, drains pending hook files, starts the hook ingress listener, the process registry, the usage refresh worker, device discovery (volumes named `SidePulse` / `PulseDot`, the Creator Micro 2 over HID every 10 s), the keep-awake and DND controllers, remote peers, cloud ingest, then the core socket. |
| A hook fires | provider → shim → ingress → collector → canonical operator state → projection → `state` and `lights` frames within one refresh. |
| Every 15 s | A controller refresh: liveness sweep, transcript tails, usage staleness, device writes if the program changed. |
| Usage | Provider usage refresh on its own worker (Claude OAuth usage endpoint when consented, Codex, Gemini, Devin, Grok, Antigravity, OpenCode, Cursor, OpenAI API where configured); one sample per window into `usage-samples.json` when the percentage moves or five minutes pass. |
| Light change | The presentation compiler clamps every program (2 Hz, 1 Hz for saturated red), the safety compiler and firmware parser validate it, the hardware worker writes `LEDS.LED` atomically to the Pro and Dot in one command when linked, and the Screen Bar receives the same program with its anchor so the band is phase-locked to the strip. |
| App quit | The app sends SIGTERM to the daemon; the daemon releases power holds, saves samples and history, and writes `off` to every strip. |

## The Python daemon by responsibility

`src/jrbar` is large (340 modules) because the 0.8 daemon is the old
application minus its windows. The map below is by job; a module not
listed is a helper of the row it sits next to alphabetically.

| Responsibility | Modules |
| --- | --- |
| Entry points and CLI | `__main__.py`, `cli.py`, `cli_entry.py`, `core_runtime.py` (the `core` subcommand), `doctor.py`, `hook_doctor.py`, `install.py`, `setup_window.py` (legacy), `integration_cli.py`, `effect_cli.py`, `provider_usage_cli*.py` |
| Core socket | `core_server.py` (transport, framing, clients), `core_projection.py` (`state` / `lights` / `settings` documents), `core_effects.py`, `core_deck.py`, `core_usage_history.py`, `core_usage_samples.py` |
| Hook path | `hook_ingress_protocol.py`, `hook_ingress.py`, `hook_pending.py`, `hook_dedupe.py`, `hook_client.py` (the Python fallback command), `hook_entry.py`, `hook.py`, `ipc.py` |
| Providers and session truth | `providers.py` (`PROVIDER_SPECS`: codex, claude, devin, grok, cursor, hermes, openclaw, opencode, antigravity, kiro, pi, gemini), `provider_adapters.py`, `provider_contracts.py`, `provider_instances.py`, `collector.py`, `process_registry.py`, `liveness_sweep.py`, `transcript_runtime.py`, `transcript_sessions.py`, `codex_hook_trust.py`, `antigravity_process_identity.py`, `origin.py`, `installed_agents.py` |
| Canonical operator state | `operator_state.py`, `provider_facts.py`, `attention.py`, `mailbox.py`, `ask_episodes.py`, `completions.py`, `completion_visibility.py`, `local_triage.py`, `freshness.py`, `intake_health.py` |
| Actions the app sends | `session_actions.py` (open in terminal / app), `answer_controller.py`, `answer_runtime.py`, `answer_in_place.py`, `clear_agents*.py`, `snooze_scope.py`, `navigation_policy.py` |
| Signals and presentation | `signals.py`, `signal_coordinator.py`, `signal_selection.py`, `presentation_policy.py`, `presentation_scheduler.py`, `presentation_compiler.py`, `render_policy.py`, `brightness_policy.py`, `auto_dim.py`, `display_brightness.py`, `interruption_policy.py`, `notification_arbitration.py`, `courtesy_signatures.py` |
| Effects | `effect_registry.py`, `effect_packs.py`, `effect_pack_store.py`, `effect_assignment_store.py`, `effect_selection.py`, `effect_studio.py`, `semantic_effect_router.py`, `ambient_effect_*.py`, `scenes.py`, `scene_packs.py`, `animation.py`, `colors.py`, `celebrations.py`, `firefly_completion.py`, `rainstick_idle.py`, `turn_length_ember.py`, `finite_effect_policy.py` |
| LED output | `led_status.py`, `led_wasm.py` (+ the packaged `sdled.wasm` firmware parser), `device_writer.py`, `hardware_write_policy.py`, `hardware_write_contract.py`, `firmware_validation.py`, `device_identity.py`, `device_inventory.py`, `device_projection.py`, `dot_binary_heartbeat.py`, `calibration_flow.py`, `draw_guard.py` |
| Screen Bar (geometry the app ports) | `virtual_device.py`, `screen_bar_design.py`, `screen_bar_pipeline.py`, `screen_bar_runtime.py`, `notch_silhouette.py`, `alcove_observation.py`, `alcove_window_probe.py` |
| Usage and quota | `provider_usage_*.py` (platform, runtime, store, sync, parsers, collectors, center, menu), `provider_capacity.py`, `capacity_*.py`, `claude_quota.py`, `usage_stats.py`, `usage_file_index.py`, `usage_pace.py`, `usage_percent_history.py`, `quota_runway.py`, `quota_power_hold.py`, `provider_reset_*.py`, `provider_credential_store.py`, `credentials.py`, `provider_browser_*.py` |
| Power | `keep_awake.py` (`caffeinate -ims`), `power_policy.py`, `lid_sleep.py` (the `pmset` helper behind `/etc/sudoers.d/jrbar-disablesleep`), `lid_presets.py`, `battery.py`, `battery_runtime.py` |
| Quiet and Focus | `dnd_policy.py`, `dnd_controller.py`, `focus_status.py`, `focus_sync.py`, `local_time_boundary.py`, `temporal_safety.py` |
| Mac signals | `calendar_watch.py`, `reminders_watch.py`, `macos_notifications.py` (legacy path), `webhook_delivery.py` |
| History | `activity_ledger*.py`, `operator_history*.py`, `session_history.py`, `capacity_history*.py`, `effect_history*.py` |
| Remote | `remote_peers.py` (Tailscale + SFTP viewer), `remote_observation.py`, `provider_usage_sync_*.py` (HMAC-signed usage sync over SSH), `cloud_ingest.py` (loopback bearer-token listener), `serve.py` (`GET /status.json` on loopback) |
| Creator Micro 2 | `creator_micro_*.py` (HID, discovery, keymap, setup, lighting), `deck_*.py` (board, controls, dispatch, actions, session board) |
| Settings and persistence | `settings.py` → `_settings_legacy.py`, `settings_installation.py`, `state_paths.py`, `migration.py`, `persistence_writer.py`, `private_io.py`, `*_store.py` |
| Scheduling | `runtime_scheduler.py`, `core_state.py`, `refresh_admission.py`, `adaptive_refresh.py`, `refresh_policy.py`, `performance_metrics.py`, `local_health.py`, `memory_probe.py` |
| Legacy AppKit UI (kept for `open_legacy_window`, retired one window at a time) | `status_bar_legacy.py`, `_status_bar_production.py`, `settings_window*.py`, `*_pane.py`, `agent_browser*.py`, `effect_studio_window.py`, `deck_control_center_window.py`, `why_panel.py`, `usage_view.py`, `main_menu.py`, `native_ui.py`, `window_presentation.py` |

`sidepulse` (in `src/sidepulse`) is a one-release import shim that aliases
`sidepulse.*` to `jrbar.*` so hook commands registered before the rename
keep working until the first launch rewrites them.

## The Swift package

| Target | Depends on | What |
| --- | --- | --- |
| `JRBarLEDS` | nothing | The LEDS DSL: parser, program model and sampler with fixture parity against the firmware's own frames (`Tests/JRBarLEDSTests/Fixtures`). Pure Swift. |
| `JRBarCore` | Foundation | The protocol: `CoreCodec` (NDJSON), `CoreMessages` / `CoreModel` (Codable documents), `CoreClient` (socket, reconnect with backoff), `CoreSupervisor`, `SettingsDocument` (typed keys per page), `PanelLayout` (fixed row heights, no measuring), `SessionLabel`, `UsageWindowLabel`, `UsageForecast` / `UsageHistory`, `LightExplanation` ("why this light"), `EventPolicy` (which event makes which sound or banner), `AutoDim`, `DeckModel`, `EffectModel`, `HistoryModel`, `AppState`. |
| `JRBarUI` | JRBarCore, AppKit | The status-item icon renderer (glyph, glyph + usage ring, glyph + label). |
| `JRBarApp` | all three | The executable: `AppDelegate`, `StatusItemController`, the panel (`PanelController` / `PanelStore` / `PanelView` / `PanelMotion`), the Screen Bar (`ScreenBarController` / `ScreenBarView` / `ScreenBarGeometry` / `ScreenBarBlend` / `ScreenBarInteraction` / `ScreenBarPanel`), `LEDFeed` (kqueue-driven file fallback), Settings (`SettingsWindowController` / `SettingsStore` / `SettingsView` / `SettingsPagesA` / `SettingsPagesB`), Usage Center, Effect Studio, Control Center and the Rail, History, `EventCoordinator` / `NotificationBridge` / `SoundPlayer` / `NotchHUD`, `SparkleUpdater`. |

Tests: `swift test` runs the LEDS parity suite, the protocol and model
tests (with `Fixtures/python-state.json`, a `state` frame produced by the
Python projection: `JRBAR_UPDATE_FIXTURES=1 pytest tests/test_core_projection.py`
regenerates it), and the mock round trips against `app/scripts/mock-core.py`.
The mock speaks protocol 1 on a socket of its choosing; never point it at
the real `core.sock` on a Mac that is running the app.

## What the app decides on its own

Everything not in this list comes from a daemon document.

- Panel geometry (`PanelLayout`), motion, keyboard handling, hover and
  selection.
- The Screen Bar's band geometry from the notch's auxiliary areas, and the
  raised-cosine blend between the eight samples (ported from
  `screen_bar_design.py`).
- Which sound or banner an `event` earns (`EventPolicy`), notification
  permission, the ask banner's Approve / Deny actions (they send
  `answer_ask`).
- The status-item look, the usage ring's colour thresholds (amber at 80 %,
  red at 95 %), and the fallback icon state from `latest.json` while the
  daemon is away.
- A local usage pace from its own `state` samples until the daemon's
  forecast has enough spread to speak.
- Login item, Screen Bar on/off, the hooks-installed stamp
  (`app-state.json`), the Sparkle channel and window conveniences
  (`UserDefaults`).
- The Lighting page's small previews of each blend mode (a reading, not the
  compiler's output; the strip is the truth).

## Invariants worth keeping

- One process owns the ingress socket. The daemon refuses to start (exit 2)
  beside another JR-Bar, the old Python status bar included.
- Every program shown or written passes the presentation compiler and the
  firmware parser. Never emit `N:off` in an indexed LEDS segment; use
  `#000000`.
- `LEDS.LED` writes are atomic and coalesced; asks, failures and finite cues
  keep their own bounded queue slots so a burst cannot starve them.
- The Screen Bar is one band. There is never a per-LED segment.
- Settings writes are validated by the real loader, saved atomically, and
  a corrupt file is preserved for recovery rather than reset.
- TCC grants belong to the signed `JR-Bar.app` identity. An ad-hoc or
  differently signed build is a different app to macOS.
- The hook shim fails open: it never blocks a provider for more than
  250 ms and never loses a payload it could queue.
- The app ignores unknown keys; the daemon ignores unknown command
  arguments. `v` is bumped only for incompatible changes.

## Build and verification

`make fast` (Ruff, import smoke, contract and focused pytest, secret scan,
dependency and version policy), `pytest tests` (the full Python suite,
about five minutes), `cd app && swift test` (the Swift suites),
`make package` (the signed bundle, PKG, Sparkle ZIP and feed;
[PRODUCTION-RELEASE.md](PRODUCTION-RELEASE.md)). CI runs the first three on
a hosted macOS 26 runner ([.github/workflows/tests.yml](../.github/workflows/tests.yml));
packaging, hardware, TCC and notarization only happen on the owner's Mac.
