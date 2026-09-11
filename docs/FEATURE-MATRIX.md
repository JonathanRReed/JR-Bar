# JR-Bar feature matrix (0.8.0)

Updated 2026-09-10 from what is installed and running on the owner's Mac
from `main`. Labels:

- **Ships**: reachable in the installed `JR-Bar.app`, exercised on the
  owner's Mac, covered by tests at its seam.
- **Ships, unverified live**: the code path is complete and tested, but the
  real device, account or tier has not yet been exercised (the reason is in
  the row).
- **Daemon only**: the daemon does it and reports it; the Swift app has no
  control for it yet (the legacy PyObjC window still can, through
  `open_legacy_window`).

Anything not in this file is not a feature. The removed planes are listed
at the end so nobody claims them.

## Sessions and intake

| Capability | Status | Default |
| --- | --- | --- |
| Hook intake through the compiled `jrbar-hook` shim (3 ms; queues to `<provider>.pending.jsonl` when no daemon listens; drained at start and every 30 s) | Ships | Always |
| Providers: Claude Code, Codex (CLI and desktop), Gemini CLI, Pi, Grok, Devin, OpenCode, OpenClaw, Antigravity | Ships | Hooks installed on first launch for every provider with a config |
| Providers: Cursor, Hermes Agent, Kiro | Ships, unverified live (none installed on the owner's Mac) | Same |
| Session liveness: process registry from the hook's `ppid` and start time, 5 s sweep, Claude `~/.claude/sessions/<pid>.json`, Codex SessionEnd/interrupt hooks and rollout tailing, pi and Gemini transcript tails | Ships (kill-to-ended measured at 2 s) | Always |
| Main sessions vs sub-agent workers; seen vs unseen completions; real asks (permission, input, approval, review) vs turns that merely end with a question | Ships | Always |
| Human session labels: the provider's own title, else project/prompt, else the working directory | Ships | Always |
| Hook doctor (`jrbar hooks doctor`; Settings › Advanced › Run Doctor) | Ships | Manual |
| First-launch hook installation and reinstall/remove per provider (Settings › Agents) | Ships | On |
| Codex trust hash computed locally for the exact command written | Ships | Always |
| T3 Code read-only session projection (`jrbar integrations`) | Ships, opt-in | Off |

## The app

| Capability | Status | Default |
| --- | --- | --- |
| Status item with three icon styles (glyph, glyph + usage ring, glyph + label), tinted by the aggregate, amber pulse during escalation | Ships | Glyph |
| Glass panel: asks pinned with Approve / Deny, sessions, usage bars, device chips, brightness, Quiet…, Clear done, keyboard navigation (↑↓ ↩ ⌘↩ ⌘D ⌘Y ⌘U ⌘K ⌘, ⌘Q) | Ships | Click the icon |
| "Why this light" row with a hover popover (programs per surface, time in state, dimming, brightness settings) | Ships | On |
| Settings window: General, Agents, Usage, Devices & Screen Bar, Lighting, Notifications & Focus, Remote, Advanced; every control writes through `set_setting`, refused writes shown | Ships | ⌘, |
| History window: rows by day, away banner, filters, Clear completed with 5-minute Undo | Ships | ⌘Y |
| Usage Center: rings per window, forecast, tokens/cost graph by day or hour, cache savings, pricing disclosure | Ships | ⌘U |
| Effect Studio: library, inspector with parameters and live preview, preview on hardware, assignments by scope, scenes, pack import/export | Ships | Settings › Lighting › Effects… |
| Control Center and the Rail for the Creator Micro 2 | Ships, unverified live (pad verified powered off only) | ⌘K |
| Notifications: ask banners with Approve / Deny, completion banners, quota banners; system sounds; notch HUD for device and peer events | Ships | Permission asked on first banner |
| Sparkle updates: manual check, opt-in automatic checks, stable/beta channel, feed on this repository's releases | Ships (no release published yet, so nothing to update to) | Automatic checks off |
| Login item (`SMAppService`) | Ships | On, registered on first launch |
| Daemon supervision: restart with backoff, "Core crashed" with Restart, orderly quit | Ships | Always |
| Legacy PyObjC windows on demand (`open_legacy_window`) | Daemon only, being retired | Manual |

## Light surfaces

| Capability | Status | Default |
| --- | --- | --- |
| SidePulse Pro and Dot output: atomic `LEDS.LED` writes through the presentation compiler and firmware parser; priority-aware write queue | Ships | On when mounted |
| Pro + Dot linked: both written in one command, the Dot replays the strip at `linked_dot_scale` (0.3) | Ships | On |
| `PulseDot` (first-batch Dot firmware) recognised as a 2-LED Dot | Ships | Automatic |
| Screen Bar: one band under the notch, the strip's program phase-locked, raised-cosine blend, 60 Hz display link that pauses when static; hover pill; click opens the session; Alcove capsule following; over full screen | Ships | On |
| Per-device display mode (agent, battery, studio, quota runway), brightness, auto-brightness, provider pin, asks-only | Ships | Agent status |
| Colour calibration per device: RGB gains, resting glow and brightness, guided sheet with named patches and a held live preview (`preview_calibration`/`end_calibration_preview`), Dot-to-strip matching, applied through the daemon | Ships | Uncalibrated |
| Global brightness; idle dim; sleep dim; auto-off | Ships | 100 %, on |
| Auto-dim: off / schedule / follow display / ambient light (IOKit HID sensor, falls back to the display) with the current reading shown | Ships | Off |
| Provider colours (dichromacy-safe defaults), blend modes, cycle speed, pulse floor and ceiling, done celebration | Ships | Reviewed defaults |
| Effects: builtins and provider animations, data-only packs, assignments by device / project / provider instance / provider / scene / state / default, reserved Needs-you and Failed effects, 2 Hz clamp (1 Hz saturated red), Reduce Motion fallback | Ships | Provider animations |
| Signals: asks, failures, completions, low battery, calendar, reminders, quota crossed, quota reset sunrise | Ships, per-feature opt-ins | Mixed |
| Escalation: light ramp → menu-bar pulse → chime every 30 s; webhook | Ships | Conservative timings |
| Studio: hand-written LEDS programs, `INIT.LED` burn | Daemon only | Off |

## Quiet, Focus and power

| Capability | Status | Default |
| --- | --- | --- |
| Quiet…: Mute, Dim, Pause, Asks-only, Dark for 30 min / 1 h / 4 h / 12 h; daily quiet schedule | Ships | Off |
| macOS Focus following with a dim rule per Focus (Full Disk Access) | Ships | Off |
| Keep awake while agents work (`caffeinate -ims`), released with a grace period when they finish; optional display assertion; battery threshold | Ships | On |
| Closed-lid policy `never` / `agents` / `always` through the `pmset` helper (one sudoers rule) | Ships | Never |
| Release the hold after repeated authoritative zero-quota evidence (`quota_power_hold`) | Ships | On |

## Usage and quota

| Capability | Status | Default |
| --- | --- | --- |
| Windows (5 h, 7 d, daily, weekly, monthly, credits) with reset times for Claude, Codex, Gemini, Devin, Grok, Antigravity, OpenCode, Cursor and an optional OpenAI API org, where the provider exposes them | Ships (Codex real turns pending the quota reset; Gemini on the derived tier) | Providers shown: all with data |
| Claude official usage endpoint via Claude Code's OAuth | Ships | Off (consent in Settings › Usage) |
| Forecast: one sample per window when the percentage moves or five minutes pass, least-squares over the last 90 minutes, `pace` and `exhausts_at`; the app extrapolates locally until the daemon has enough spread | Ships | On |
| Tokens and cost by day or hour from local transcripts (7d–365d), cache savings, list-price disclosure | Ships (the daemon reports no price table yet, so the cost lines read as approximate) | On |
| Quota alerts: threshold effects, pace notifications, reset sunrise sweep and banner | Ships | Off |
| Quota Runway device display | Ships | Selectable per device |
| Capacity history and operator history behind retention consent | Ships | Off |
| Browser-session import for provider auth, secrets in Keychain | Daemon only | Off |

## Remote and integrations

| Capability | Status | Default |
| --- | --- | --- |
| Remote peers: read-only ledger of another Mac over Tailscale + SFTP, bounded and stale-aware | Ships | Off |
| Cross-Mac usage sync: HMAC-SHA256-signed JSON over SSH | Ships | Off |
| Cloud ingest: loopback listener with a 256-bit bearer token in the state dir | Ships | Off |
| Webhook: JSON moments to one HTTPS URL, event list chosen in Settings › Remote | Ships | Off |
| `jrbar serve`: `GET /status.json` on loopback with redacted aggregates and quota summaries (Stream Deck, scripts) | Ships | Manual |
| Calendar and Reminders glows | Ships | Off |

## Packaging and diagnostics

| Capability | Status | Default |
| --- | --- | --- |
| `make package`: one signed bundle (app, frozen daemon as a nested helper app, shim, pinned Sparkle 2.9.6), PKG for `/` or `~`, Sparkle ZIP, signed appcast when the key is in the keychain | Ships (Developer ID signed; not notarized until the `jrbar-notary` profile exists) | Manual |
| `make clean-install`: home-directory install without a password | Ships | Manual |
| Doctor: `jrbar doctor` and Settings › Advanced (commit the daemon was built from, memory, sockets, hooks, devices, checks) | Ships | Manual |
| SidePulse → JR-Bar migration of config, state, data, hooks, LaunchAgents, Keychain items | Ships | Automatic, once |
| `make fast`, the full pytest suite, `swift test`, and CI on hosted macOS 26 | Ships | Every push |

## Removed in 0.8

Not features; do not claim them anywhere: the iOS companion app and its
Mac half (`glance`, `serve --phone-glance`), the external Agent Deck
snapshot bridge, the Waybar client, severe-weather alerts, the
timebox/timer and its Shortcuts handshake, the operator history export,
night warmth and the fixed 7 PM–7 AM dim (replaced by auto-dim), the PyObjC
status bar as a UI (`jrbar status-bar` refuses to run beside the daemon),
the architecture-policing meta-tests, and the old multi-receipt release
gate (`verify_macos_release.sh`, `publish_release.sh`) as the way releases
happen. Earlier removals (the delivery-planning plane, `runtime_truth`,
the quota-forecast authority, the status-audit exporters) stay removed.
