# Feature disposition

What was kept, cut or left half-built in the 0.8 rebuild, and why. Scores
are value to JR-Bar from 0 (remove) to 5 (essential). Updated 2026-09-10;
the September 4 inventory this replaces is resolved line by line below.
The status authority for what ships is [FEATURE-MATRIX.md](FEATURE-MATRIX.md).

## Kept and shipped in 0.8

| Feature | Score | Disposition | Where |
| --- | ---: | --- | --- |
| Session truth (shim, process liveness, Claude session files, Codex/pi/Gemini tails) | 5 | Shipped; the reason 0.8 exists | `hook/`, `process_registry.py`, `liveness_sweep.py`, `transcript_runtime.py` |
| Escalation for real asks only | 5 | Shipped; Approve / Deny in the panel and banners | `attention.py`, `EventPolicy`, `NotificationBridge` |
| Screen Bar as one band, phase-locked to the strip | 5 | Shipped; the mirror is deliberate (the owner does not want a segmented announcer) | `ScreenBarController`, `ScreenBarBlend` |
| Pro + Dot linked mode | 5 | Shipped (`devices_linked`, `linked_dot_scale`) | `device_writer.py`, `core_projection.py` |
| Colour calibration | 5 | Shipped; the Devices page's Calibrate… sheet previews live | `calibration_flow.py`, `SettingsPagesA` |
| Usage forecast (CodexBar-style pace) | 5 | Shipped; daemon samples with an app-side fallback | `core_usage_samples.py`, `UsageForecast` |
| Effect Studio with data-only packs | 5 | Shipped, merged into the app | `effect_*.py`, `EffectStudioView` |
| Auto-dim (schedule / display / ambient) | 4 | Shipped; replaces night warmth | `auto_dim.py`, `AutoDim` |
| Closed-lid keep-awake with release when agents finish | 5 | Shipped | `keep_awake.py`, `lid_sleep.py`, `quota_power_hold.py` |
| Activity History with the away banner | 4 | Shipped | `activity_ledger*.py`, `HistoryView` |
| Calendar and Reminders glows, Focus dimming, quiet schedule | 4 | Shipped, opt-in | `calendar_watch.py`, `reminders_watch.py`, `focus_sync.py`, `dnd_*.py` |
| Remote peers, cross-Mac usage sync, cloud ingest, webhook | 4 | Shipped, opt-in | `remote_peers.py`, `provider_usage_sync_*.py`, `cloud_ingest.py`, `webhook_delivery.py` |
| Creator Micro 2 Control Center and Rail | 4 | Shipped in source; pad verified powered off only | `core_deck.py`, `ControlCenterView`, `DeckRailController` |
| T3 Code read-only projection | 4 | Kept, opt-in | `t3_compat.py`, `usage_graph_worker.py` |
| Alcove capsule following | 4 | Kept in the daemon; the app's band uses its width | `alcove_observation.py` |
| `jrbar serve` loopback API | 3 | Kept, manual | `serve.py` |
| Provider-exhaustion hold release, statuspage incident rows, reset delivery ledger, account aliases and privacy mode, Claude consent path, Devin reconnect safety | 4 | Kept from 0.6/0.7 unchanged | as before |
| Mailbox v1 settings migration | 1 | Kept; removing it breaks old settings files | `mailbox_preference_store.py` |

## Cut in 0.8

| Feature | Score | Why |
| --- | ---: | --- |
| iOS companion app and the Mac glance/push half | 0 | Nobody used it; a second platform for one person |
| External Agent Deck snapshot bridge | 0 | The built-in deck is the Control Center; the bridge duplicated it |
| Waybar client | 0 | Linux desktop client for a Mac product |
| Severe-weather alerts | 0 | Scope creep; the clearest marker of it in the codebase |
| Timebox / timer, its Shortcuts handshake and device display | 0 | Not what the light is for |
| Operator export (JSON dump, Local Export card) | 0 | Diagnostics come from Doctor now |
| Night warmth and the fixed 7 PM–7 AM dim | 1 | Replaced by auto-dim, which knows the time and the room |
| Architecture-policing meta-tests | 0 | They tested the shape of the Python UI that no longer exists |
| Dead settings dials (`closed_lid_system_override_enabled`, `local_activity_history_enabled`, `forecast_release_authority`), `signals.quota_resets`, `interruption_policy.plan_deliveries`, `LID_ANIMATION_CHOICES` | 0 | No callers |
| The multi-receipt release gate as the release path | 1 | `make package` is the release; the scripts stay only until their tests are retired |

## Still open

| Feature | Score | Disposition |
| --- | ---: | --- |
| Legacy PyObjC windows behind `open_legacy_window` | 1 | Retire one at a time as each Swift replacement is confirmed complete |
| Studio (hand-written LEDS programs, `INIT.LED` burn) | 3 | Daemon only; needs a Swift surface or a decision to fold it into Effect Studio |
| Browser-session import for provider auth | 2 | Daemon only; no Swift consent flow yet |
| Price table served by the daemon | 3 | The Usage Center reads "no price table" until it exists |
| Dial and Joystick mapping editor | 3 | Settings › Devices shows the mappings but cannot edit them |
| Screen Bar notch-silhouette measurement and standing gauges | 2 | Python had them; the Swift band uses the notch's auxiliary areas |
| Linux headless daemon | 2 | The daemon boundary makes it possible; no demand yet |
| Windows | 0 | No |
