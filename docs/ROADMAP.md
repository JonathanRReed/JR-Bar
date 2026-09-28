# JR-Bar roadmap

Updated 2026-09-27. Version 0.9.13 is in local testing with a signed,
notarized and stapled app. The public release is still pending.
[FEATURE-MATRIX.md](FEATURE-MATRIX.md) describes implemented capabilities;
a source path is not a physical acceptance receipt.

## Before the first public release

1. Finish the audit repairs and verify the installed candidate. Transcript
   parsing now streams lines, Screen Bar planning runs off-main with bounded
   admission, and upgrades preserve chosen hook integrations. Setup asks
   about permissions used by enabled features. Combined tests pass locally;
   packaging and installed parity must follow the final source changes.
2. Verify an early weekly quota reset on a real account. Jonathan accepted
   Fold at rest with parking off, menu-bar clicks, long Dock titles,
   centered compact actions and fish hover on the installed test build.
   Fixture coverage cannot prove a natural reset celebration.
3. Collect controlled performance measurements. Record warm launch, menu
   and pane latency, main-thread work and idle CPU against the release
   budgets. Complete the [Screen Bar profile matrix](SCREEN-BAR-PROFILING.md).
   Synthetic parsing benchmarks are useful evidence for that parser only.
4. Finish signing and release acceptance. Developer ID Application,
   notarization and Sparkle keys are available. The Developer ID Installer
   identity is still missing. Physical hardware/provider checks and the
   system uninstall receipt also remain open. The
   [production release gate](PRODUCTION-RELEASE.md) must pass before publishing.
5. Verify the public entry. Keep setup instructions and screenshots current,
   make the support route usable, then publish the signed installer and
   update archive once their receipts pass. Until then, Releases has no
   downloadable public build.

## Later work

- Creator Micro 2 live acceptance. Check human approval, session keys,
  dial and joystick mappings, keymap backup/restore, and USB/Bluetooth
  arrival and departure. Previous checks covered a powered-off pad only.
- Real Codex and Gemini turns. Verify asks, completion/interrupt handling
  and the account's actual quota windows. Old quota reset dates do not
  establish current acceptance.
- Move provider adapters to Swift one at a time if measurements justify
  it. Keep the core protocol stable while doing so.
- Reassess the deferred parity items from the
  [2026-09-21 audit](archive/audits/2026-09-21-systems-audit.md), including
  optional live Dock thumbnails, widget hosting, island gestures and
  broader token/cost history. Reliability and resource use come first.

## Deliberately not planned

- A phone companion, a Waybar client, severe-weather alerts, a timebox
  timer, operator export, the external Agent Deck bridge: deleted in 0.8
  and not coming back in that shape. Two things with similar names stay:
  the notch card's Weather row (off by default, a keyless Open-Meteo read
  of a city you type, IP location only if you opt in) and the shelf's
  agent timers (a countdown to a quota reset, or a nudge if a session is
  still running).
- Executable effect plugins. Effects stay data-only JSON packs.
- Windows or a native Linux runtime. Only remote-peer viewing crosses the
  Mac boundary.

## Upstream research

Upstream (SidePulse, CodexBar, T3 Code) is reviewed on the cadence in
[UPSTREAM-RESEARCH-CADENCE.md](UPSTREAM-RESEARCH-CADENCE.md); the
current snapshot is the [2026-08-30 refresh](UPSTREAM-REFRESH-2026-08-30.md).
