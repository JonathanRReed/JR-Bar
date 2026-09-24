# JR-Bar roadmap

Updated 2026-09-21. 0.8.0 shipped the Swift app over the bundled Python
daemon; 0.9.9 is what runs on the owner's Mac now — signed, notarized and
stapled. The plan that got it here is [PLAN-0.8.md](PLAN-0.8.md); what
ships is [FEATURE-MATRIX.md](FEATURE-MATRIX.md). This is the short list of
what comes after, in rough order.

## After 0.9

1. **A first public release.** The app is already Developer-ID signed,
   notarized and stapled. The PKG is installable but unsigned — there is
   no Developer ID Installer identity in the keychain, so the package
   itself can never be notarized (only signed PKGs can); the stapled app
   inside is what carries the trust. Either add an installer identity so
   the PKG carries its own ticket, or ship the notarized ZIP as the
   primary artifact. Then cut `v0.9.x`, upload the PKG and ZIP, and the
   signed `appcast.xml` to the `updates` release — the Sparkle feed 404s
   until a release exists ([PRODUCTION-RELEASE.md](PRODUCTION-RELEASE.md)).
2. **Creator Micro 2 live verification.** The pad has been verified
   powered off only (approval, keymap plan, the board without hardware).
   Turn it on and exercise: approval on first sight, a session key press
   answering an ask when the terminal is frontmost, the dial and joystick
   mappings, keymap apply with backup and restore, USB and Bluetooth
   arrival and departure.
3. **Codex and Gemini real-turn verification.** Both providers are wired
   and fixture-tested; the owner's Codex quota resets 2026-09-14 and Gemini
   was verified on the derived tier only. Run real turns through each,
   confirm the ask lane, the SessionEnd/interrupt path for Codex, and the
   usage windows.
4. **Adapters in Swift.** The protocol was drawn so provider adapters can
   move to Swift one at a time without the app noticing. Start with the
   session-truth pieces that are already process-table work (liveness,
   Claude session files), then the transcript tails, leaving the daemon
   with usage, devices and policy.
5. **Retire the legacy windows.** Done 2026-09-24: `open_legacy_window` is
   gone, the Creator Micro's window keys ask the app for its own windows,
   and the Setup, Effect Studio, Control Center and Why panel windows are
   deleted. The Settings window and the modules only it imports go with the
   settings-window removal (SP-10).
6. **Smaller things.** A real app icon (the current one is programmatic);
   the Screen Bar's notch-silhouette measurement and standing gauges on
   the Swift side; a price table served by the daemon so the Usage Center's
   cost lines stop reading "no price table"; the Dial and Joystick mapping
   editor in Settings › Devices.
7. **The 2026-09-21 audit's deferred parity work** (see
   [audits/2026-09-21-systems-audit.md](audits/2026-09-21-systems-audit.md)):
   live Dock thumbnails behind an opt-in (SCStream costs the persistent
   recording indicator — stills were the deliberate choice, but the option
   is parity with DockDoor); a widget extension target (the snapshot
   writer and decoder already exist, the target needs an Xcode project);
   pinch/squeeze on the island; inbound AirDrop progress capsules; system
   notifications rendered *in* the island rather than as pills under it;
   Dock preview keyboard walk without the pointer; token/cost history
   beyond Claude and Codex transcripts.

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
