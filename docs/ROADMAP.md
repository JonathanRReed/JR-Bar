# JR-Bar roadmap

Updated 2026-09-10. 0.8.0 shipped: the Swift app over the bundled Python
daemon, running on the owner's Mac from `main`. The plan that got it there
is [PLAN-0.8.md](PLAN-0.8.md); what ships is [FEATURE-MATRIX.md](FEATURE-MATRIX.md).
This is the short list of what comes after, in rough order.

## After 0.8

1. **Notarized releases.** `make package` already signs with the Developer
   ID identity and staples when the `jrbar-notary` keychain profile exists;
   the profile has not been created yet, so the built PKG is not
   distributable to another Mac. Create the profile, cut `v0.8.x`, upload
   the PKG and ZIP, then the signed `appcast.xml` to the `updates` release
   ([PRODUCTION-RELEASE.md](PRODUCTION-RELEASE.md)).
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
5. **Retire the legacy windows.** `open_legacy_window` still opens the
   PyObjC Settings, Setup, Agent Browser, Effect Studio, Usage Center,
   Control Center and Why panel on demand. Each has a Swift replacement;
   delete them from the daemon as the replacements are confirmed complete.
6. **Smaller things.** A real app icon (the current one is programmatic);
   the Screen Bar's notch-silhouette measurement and standing gauges on
   the Swift side; a price table served by the daemon so the Usage Center's
   cost lines stop reading "no price table"; the Dial and Joystick mapping
   editor in Settings › Devices.

## Deliberately not planned

- A phone companion, a Waybar client, weather, a timebox timer, operator
  export, the external Agent Deck bridge: deleted in 0.8 and not coming
  back in that shape.
- Executable effect plugins. Effects stay data-only JSON packs.
- Windows or a native Linux runtime. Only remote-peer viewing crosses the
  Mac boundary.
