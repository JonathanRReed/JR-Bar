# JR-Bar feature matrix

Updated 2026-09-27. Version 0.9.14 is in local testing. The installed
candidate is Developer ID signed, notarized and stapled. No public release
has been published.

- **Implemented** means a reachable source path with regression coverage.
  It does not establish current physical acceptance for every provider,
  permission, device or interaction.
- **Implemented, unverified live** identifies a known missing real-device
  or account check. Those checks remain required before release.
- **Daemon only** means the daemon reports the capability, but the Swift
  app has no control for it. Use `jrbar` or the core protocol.

The [roadmap](ROADMAP.md) lists the remaining acceptance and release work.

## Sessions and intake

| Capability | Status | Default |
| --- | --- | --- |
| Hook intake through the compiled `jrbar-hook` shim (3 ms; queues to `<provider>.pending.jsonl` when no daemon listens; drained at start and every 30 s) | Implemented | Always |
| Providers: Claude Code, Codex (CLI and desktop), Gemini CLI, Pi, Grok, Devin, OpenCode, OpenClaw, Antigravity | Implemented | Connect each chosen provider in Settings › Agents |
| Providers: Cursor, Hermes Agent, Kiro | Implemented, unverified live (none installed on the owner's Mac) | Same |
| Session liveness: process registry from the hook's `ppid` and start time, 5 s sweep, Claude `~/.claude/sessions/<pid>.json`, Codex SessionEnd/interrupt hooks and rollout tailing, pi and Gemini transcript tails | Implemented (kill-to-ended measured at 2 s) | Always |
| Main sessions vs sub-agent workers; seen vs unseen completions; real asks (permission, input, approval, review) vs turns that merely end with a question | Implemented | Always |
| Human session labels: the provider's own title, else project/prompt, else the working directory | Implemented | Always |
| Hook doctor (`jrbar hooks doctor`; Settings › Advanced › Run Doctor) | Implemented | Manual |
| Chosen hook installation and reinstall/remove per provider (Settings › Agents); upgrades refresh owned integrations and preserve disabled flags | Implemented | Manual selection |
| Codex trust hash computed locally for the exact command written | Implemented | Always |
| T3 Code read-only session projection (`jrbar integrations`) | Implemented, opt-in | Off |

## The app

| Capability | Status | Default |
| --- | --- | --- |
| Status item with six icon styles (session dots, usage meters, meters + percent, glyph, glyph + usage ring, glyph + label), tinted by the aggregate, amber pulse during escalation | Implemented | Session dots |
| Glass panel: asks pinned with Approve / Deny, sessions, usage bars, device chips, brightness, Quiet…, Clear done, keyboard navigation (↑↓ ↩ ⌘↩ ⌘D ⌘Y ⌘U ⌘K ⌘, ⌘Q) | Implemented | Click the icon |
| "Why this light" row with a hover popover (programs per surface, time in state, dimming, brightness settings) | Implemented | On |
| Settings window: General, Agents, Usage, Devices & Screen Bar, Utilities, Lighting, Toys, Notifications & Focus, Remote, Advanced; every daemon control writes through `set_setting`, refused writes shown | Implemented | ⌘, |
| First-run setup walkthrough: Welcome, Agents, Permissions, Menu bar & Screen Bar, Done; re-runnable from Settings | Implemented | First two launches |
| History window: rows by day, away banner, filters, Clear completed with 5-minute Undo | Implemented | ⌘Y |
| Overview window: sidebar presets (Needs me, Working, Unreviewed, This project, This Mac, All connected), scoped roster table, summary strip, inspector with per-session transcript Timeline (Claude/Codex, paginated), saved filters, search, two-run Compare sheet | Implemented | ⌘O |
| Event Replay window: read-only journaled events, persistent REPLAY badge, journal coverage, live-attention indicator kept separate | Implemented | ⌘R |
| Usage Center: rings per window, forecast, tokens/cost graph by day or hour, cache savings, pricing disclosure | Implemented | ⌘U |
| Effect Studio: library, inspector with parameters and live preview, preview on hardware, assignments by scope, scenes, pack import/export | Implemented | Settings › Lighting › Effects… |
| Control Center and the Rail for the Creator Micro 2 | Implemented, unverified live (pad verified powered off only) | ⌘K |
| Notifications: ask banners with Approve / Deny, completion banners, quota banners; system sounds; notch HUD for device and peer events | Implemented | Permission asked on first banner |
| Sparkle updates: manual check, opt-in automatic checks, stable/beta channel, feed on this repository's releases | Implemented (no release published yet, so nothing to update to) | Automatic checks off |
| Login item (`SMAppService`) | Implemented | On, registered on first launch |
| Daemon supervision: restart with backoff, "Core crashed" with Restart, orderly quit | Implemented | Always |

## Light surfaces

| Capability | Status | Default |
| --- | --- | --- |
| SidePulse Pro and Dot output: atomic `LEDS.LED` writes through the presentation compiler and firmware parser; priority-aware write queue | Implemented | On when mounted |
| Pro + Dot linked: both written in one command, the Dot replays the strip at `linked_dot_scale` (0.3) | Implemented | On |
| `PulseDot` (first-batch Dot firmware) recognised as a 2-LED Dot | Implemented | Automatic |
| Screen Bar: one band under the notch, the strip's program phase-locked, raised-cosine blend, 60 Hz display link that pauses when static; hover pill; band click pins its card; the left session mark opens the session; Alcove capsule following; over full screen | Implemented | On |
| Per-device display mode (agent, battery, studio, quota runway), brightness, auto-brightness, provider pin, asks-only | Implemented | Agent status |
| Colour calibration per device: RGB gains, resting glow and brightness, guided sheet with named patches and a held live preview (`preview_calibration`/`end_calibration_preview`), Dot-to-strip matching, applied through the daemon | Implemented | Uncalibrated |
| Global brightness; idle dim; sleep dim; auto-off | Implemented | 100 %, on |
| Auto-dim: off / schedule / follow display / ambient light (IOKit HID sensor, falls back to the display) with the current reading shown | Implemented | Off |
| Provider colours (dichromacy-safe defaults), blend modes, cycle speed, pulse floor and ceiling, done celebration | Implemented | Reviewed defaults |
| Effects: builtins and provider animations, data-only packs, assignments by device / project / provider instance / provider / scene / state / default, reserved Needs-you and Failed effects, 2 Hz clamp (1 Hz saturated red), Reduce Motion fallback | Implemented | Provider animations |
| Signals: asks, failures, completions, low battery, calendar, reminders, quota crossed, quota reset sunrise | Implemented, per-feature opt-ins | Mixed |
| Escalation: light ramp → menu-bar pulse → chime every 30 s; webhook | Implemented | Conservative timings |
| Smart suppression: an ask whose terminal pane is frontmost gets its banner but no burst, pulse or chime (host bundle + process-ancestry proof, `answer_local`'s read); walking away re-arms the stage | Implemented | On |
| Studio: hand-written LEDS programs, `INIT.LED` burn | Daemon only | Off |

## Toys (the Toys page)

| Capability | Status | Default |
| --- | --- | --- |
| Fold: lid-angle animation with Duo as the default look, Room as an alternate, and optional Bendy or Lid Plane handoff | Implemented | Off; needs Screen Recording |
| Aquarium: every live session is a fish in a resizable tank window; idle game (pearls, shop, level, streaks, achievements, residents, fry schools) | Implemented | Off |
| Notch Buddy: a creature by the notch that lives by agent state; ten characters, draggable off the notch, Tamagotchi-lite care log | Implemented | Off |
| Confetti: a burst in the provider's colours out of the notch's lip (or the icon, the corners, or rain), landing on window tops and the Dock — weekly reset by default; session-completion, per-provider, banked-credits, all-clear and milestone triggers opt in; sizes, palettes, shapes, seasonal and moment styles | Implemented | Off |

## Utilities (the Utilities page)

| Capability | Status | Default |
| --- | --- | --- |
| Notch island: capsule hugging the notch — live counts, expand-on-hover card, event capsules (asks, completions, failures, quota resets, charging), Now Playing via the `mediaremote` helper, media HUD, system alerts, weather, Mirror row, audio visualizer, shelf; Alcove or Boring Notch can own the notch instead | Implemented | Off |
| Menu Bar: hide items behind the JR-Bar item (the concealer on macOS 27, spacer engine elsewhere), reveal gestures, Item Bar with live tiles, ⌘⇧K command bar, hotkeys, triggers, profiles, cover appearance; Bartender, Ice or Hidden Bar can be handed the surface instead | Implemented | On (utility enabled; nothing hidden until items are dragged over) |
| Dock: hover window previews over Apple's Dock, per-window actions, app switcher; DockDoor or ActiveDock can render instead | Implemented | Off |
| Agent Overview: the roster card — counts by state, session verbs (open, approve/deny, dismiss, snooze, clear), ⌘O window | Implemented | On |
| Data Hoarder: local searchable archive of traces and session files — hash-deduped copies, per-source import consent, full export, recoverable Archive Trash; no automatic capture or proxy connection yet | Implemented (capture is manual/import-only so far) | Off |

## Quiet, Focus and power

| Capability | Status | Default |
| --- | --- | --- |
| Quiet…: Pause, Dim, Mute, Asks-only, Dark for 30 min / 1 h / 4 h / until 08:00 tomorrow; the panel shows the active quiet (footer label + moon glyph) and can cancel an override; daily quiet schedule | Implemented | Off |
| macOS Focus following with a dim rule per Focus (Full Disk Access) | Implemented | Off |
| Keep awake while agents work (`caffeinate -ims`), released with a grace period when they finish; optional display assertion; battery threshold | Implemented | On |
| Closed-lid policy `never` / `agents` / `always` through the `pmset` helper (one sudoers rule) | Implemented | Never |
| Release the hold after repeated authoritative zero-quota evidence (`quota_power_hold`) | Implemented | On |

## Usage and quota

| Capability | Status | Default |
| --- | --- | --- |
| Windows (5 h, 7 d, daily, weekly, monthly, credits) with reset times for Claude, Codex, Gemini, Devin, Grok, Antigravity, OpenCode, Cursor and an optional OpenAI API org, where the provider exposes them | Implemented (Codex real turns pending the quota reset; Gemini on the derived tier) | Providers shown: all with data |
| Claude official usage endpoint via Claude Code's OAuth | Implemented | Off (consent in Settings › Usage) |
| Forecast: one sample per window when the percentage moves or five minutes pass, least-squares over the last 90 minutes, `pace` and `exhausts_at`; the app extrapolates locally until the daemon has enough spread | Implemented | On |
| Tokens and cost by day or hour from local transcripts (7d–365d), cache savings, list-price disclosure | Implemented (the daemon reports no price table yet, so the cost lines read as approximate) | On |
| Quota alerts: threshold effects, pace notifications, reset sunrise sweep and banner | Implemented | Off |
| Reset countdown on the quota ear (drain arc inside the ring + words in the peek and island card) and provider incident badges from the status feeds (ear tone, panel row, Usage Center header) | Implemented | On |
| Quota Runway device display | Implemented | Selectable per device |
| Capacity history and operator history behind retention consent | Implemented | Off |
| Devin browser-session import: exact CLI consent, Usage Center import and revoke, token in Keychain | Implemented | Off |

## Remote and integrations

| Capability | Status | Default |
| --- | --- | --- |
| Remote peers: read-only ledger of another Mac over Tailscale + SFTP, bounded and stale-aware | Implemented | Off |
| Cross-Mac usage sync: HMAC-SHA256-signed JSON over SSH | Implemented | Off |
| Cloud ingest: loopback listener with a 256-bit bearer token in the state dir | Implemented | Off |
| Webhook: JSON moments to one HTTPS URL, event list chosen in Settings › Remote | Implemented | Off |
| `jrbar serve`: `GET /status.json` on loopback with redacted aggregates and quota summaries (Stream Deck, scripts) | Implemented | Manual |
| Calendar and Reminders glows | Implemented | Off |

## Packaging and diagnostics

| Capability | Status | Default |
| --- | --- | --- |
| `make package`: one signed bundle (app, frozen daemon as a nested helper app, shim, pinned Sparkle), PKG for `/` or `~`, Sparkle ZIP, signed appcast when the key is in the keychain | Implemented; the 0.9.14 test PKG and app are Developer ID signed, notarized and stapled, and the PKG passed a home install. No public release has passed the full gate. | Manual |
| `make clean-install`: home-directory install without a password | Implemented | Manual |
| Doctor: `jrbar doctor` and Settings › Advanced (commit the daemon was built from, memory, sockets, hooks, devices, checks) | Implemented | Manual |
| SidePulse → JR-Bar migration of config, state, data, hooks, LaunchAgents, Keychain items | Implemented | Automatic, once |
| `make fast`, the full pytest suite, `swift test`, and CI on hosted macOS 26 | Implemented | Every push |

## Removed in 0.8

Not features; do not claim them anywhere: the iOS companion app and its
Mac half (`glance`, `serve --phone-glance`), the external Agent Deck
snapshot bridge, the Waybar client, severe-weather alerts, the
timebox/timer and its Shortcuts handshake, the operator history export,
night warmth and the fixed 7 PM–7 AM dim (replaced by auto-dim), the PyObjC
status bar as a UI (removed: `jrbar setup` installs no LaunchAgent, the
daemon unloads the old one, and `jrbar status-bar` only manages the sleep
helper), its NSMenu dropdown, and the PyObjC windows the daemon could open
on demand (`open_legacy_window`: Settings, Setup, Agent Browser, Effect
Studio, Usage Center, Control Center, the Why panel; the Creator Micro's
window keys open the app's windows instead),
the architecture-policing meta-tests. The current release gate is
`verify_macos_release.sh`, with candidate-bound receipts checked before
`publish_release.sh` publishes. Earlier removals (the delivery-planning plane, `runtime_truth`,
the quota-forecast authority, the status-audit exporters) stay removed.
