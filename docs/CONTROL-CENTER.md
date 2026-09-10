# JR-Bar Control Center

The Control Center is a Swift window (`app/Sources/JRBarApp/ControlCenterView.swift`,
title "Control Center", subtitle "Creator Micro 2"). It renders `state.deck`
from the daemon and sends `deck_*` commands back over the core socket. It does
not talk to the pad. Every decision — which identity owns a slot, what a press
does, whether a keymap write is safe — is made in the daemon and documented on
the wire in [CORE-PROTOCOL.md](CORE-PROTOCOL.md#the-creator-micro-2-deck-statedeck).
The window is a view and a set of requests.

That split is why the window opens with **Core not connected** when the daemon
is not up: there is no local model to fall back on, and inventing one would let
the screen disagree with the pad.

Open it with ⌘K from the panel, from the panel footer's overflow menu, from the
status menu, from the app menu, or from **Settings › Devices › Open Control
Center…**.

## Start without hardware

No Creator Micro 2, Work Louder Input, CodexBar, T3 install, notch or accessory
is needed for the workspace itself. The session board and the compact rail work
on their own; the pad, when it is there, mirrors them.

The board reserves stable slots for canonical provider/source/work identities.
A refresh never sorts an existing key onto a different session. A session that
disappears keeps its slot as **Not observed**. **Pin / unpin** (`deck_pin`)
keeps a slot through **Clear absent…** (`deck_clear_absent`); pins follow the
identity, not the key. Previous/next banks (`deck_bank`) handle overflow. Drag a
session from the Sessions list onto a key to pin it there. Only opaque identity
hashes are persisted — never project names, paths, transcript text or
credentials.

The optional **Compact rail** (`deck_rail`, `DeckRailController.swift`) puts the
same slots against the selected display's left, right, top or bottom visible
edge, with state words, accessible labels and tooltips on the compact marks.
Closing the workspace leaves an enabled rail up; choose **off** to remove it.
The edge is saved with the board and restored on the next open, including after
a restart. The rail never opens before the workspace, and the display is
resolved again rather than remembered as a stale screen identity.

A visible session is not automatically controllable. Pressing a session key
answers a live ask only when that session has one *and* the frontmost app is its
terminal or origin app; otherwise it reveals the session through the board's
navigation resolver. Unavailable navigation is refused rather than launching a
guessed terminal or emulating an approval.

## Connect a Creator Micro 2

Enable the master connection under **Settings › Devices**, or press **Approve**
in the Control Center's device card (`deck_approve_device`). Approval is bound
to one stable serial. The daemon probes HID again at approval time and refuses
with "No Creator Micro 2 is connected." rather than enabling a remembered serial
blindly. USB wins over Bluetooth only when both records identify the same board
unambiguously; missing serials, duplicate same-transport endpoints and
conflicting replies are refused.

Close Work Louder Input and other device controllers before taking over. JR-Bar
does not silently terminate them, and the firmware has no ownership handshake:
RPC replies are not a lock, and concurrent writers can still corrupt the single
stream. Conflict detection is a stop condition, not permission to keep writing.

With **Session keys and per-session lighting** off, the runtime uses temporary
whole-board `lights.preview` output and leaves stock key mappings alone. With it
on, unmapped AG00–AG12 follow the current session bank; explicit saved actions
override navigation. Per-key colors need those AG keycodes in the active
firmware keymap and `v.oai.thstatus` support, and are device-wide rather than
per-layer.

## Configure keys, encoders and joystick inputs

**Apply keymap…** plans first (`deck_plan_keymap`) and applies second
(`deck_apply_keymap`). Planning reads the complete bounded keymap; it does not
program it. Choose the stored profile and layer, optionally include supported
auxiliary mappings, and read the exact list of firmware-generated
keystrokes/macros that will be unbound. Unknown fields, unselected profiles and
unselected layers are preserved.

The base matrix maps 13 keys. The auxiliary transformation supports three-entry
encoder rows and joystick sector dictionaries carrying a `k` keycode, within the
firmware's 20 AG-slot budget. Unknown shapes and oversized selections are
refused, not guessed. Numeric encoder labels do not claim a physically verified
direction, and the profile/layer must still be selected on the device — no
undocumented profile-switch command is sent.

Before replacing `keymap.json` the daemon saves and verifies the first private
backup, proves binary transfer on a uniquely named scratch file, rechecks device
identity and generation and the original bytes, then records recovery progress
before each destructive step. Reads and writes are offset-based and bounded.
Device SHA-1 plus a complete byte readback establishes **stored bytes**, not
active firmware behaviour: reconnect the board if its firmware has not activated
the stored map.

After a verified write, **Check input** (`deck_check_input`) turns itself on and
the header says "Input check: device actions are paused". Press every key, turn
and press the dial, exercise the joystick, and confirm the observed logical
input appears before re-enabling actions. Closing the window does not resume
them; uncheck Check input explicitly.

For continuous `v.oai.rad` input, enable **analog joystick sectors**
(`deck_set_settings`). Four numbered sectors appear as mapping destinations
20–23. Each excursion emits at most one action and must return to the dead zone
first. Confirm each physical direction in Input check: angle zero and polarity
are not assumed to mean up or right. Existing discrete joystick key mappings can
stay as they are.

## Map actions

Under **Settings › Devices**, pick the logical key, pick an action, **Save
mapping**. Actions include an installed app, a recorded shortcut for that
frontmost app, revealing the current ask, Agent Browser, Usage Center, Control
Center, bank changes, and a named macOS Shortcut.

App shortcuts need Accessibility permission and the exact mapped application
frontmost. A macOS Shortcut runs by its exact name through `/usr/bin/shortcuts`
with fixed argv and no shell expansion; its receipt distinguishes queued,
finished, failed, expired and timed out. Cancelling the runner cannot undo side
effects a started Shortcut has already performed. Device events and provider
text never supply executable code or command arguments.

**Run selected mapping…** is the explicit virtual-input path: it confirms first
and uses the same bounded dispatcher as physical input, and Input check pauses
it too. Actions expire rather than replay after a delayed UI, a reconnect, a
remapping, a bank change or a termination. Queue overload is counted.

**Import mappings…** reads one explicitly chosen JSON file, previews its
actions, and imports with actions disabled. **Export mappings…** writes the
data-only host mappings. Neither is a general firmware file editor, and none is
implemented here.

## Recovery and uninstall

Use **Export original keymap…** to keep your own copy before experimenting. The
first original stays in a private device-identity-scoped backup beside the
integration settings, and a separate `.recovery.json` records interrupted
operations. Do not delete either while a recovery is pending.

After **Recovery required**, use **Restore keymap…** (`deck_restore_keymap`) —
not another Apply, which is refused until the recovery resolves. If the original
is already intact, Restore verifies those bytes and clears the pending recovery
with no device write. Restore accepts only the original, JR-Bar's verified map,
or a pending write's recorded original or prefix; unrelated later device edits
cause a refusal. A reconnect starts a new transfer generation and never resumes
an old write on its own.

Before uninstalling JR-Bar, restore the original map and verify it on the board,
then disable device actions and the master connection. AG keycodes replace
ordinary keystrokes and depend on a host handler: removing the app alone does
not restore the firmware map.

## Provider compatibility

T3 is an optional read-only SQLite source. The compatibility manifest records a
source review of `ea646c0834a3394ecb0be4a30c5d367e5a9002bd`; the highest
**tested** version is still 0.0.33, and a source review is not a live
compatibility certification. Missing native thread IDs are accepted without
reusing T3's own IDs as native resume IDs. A ready or idle transport is not
successful completion — only an unambiguous completed-turn projection is. Gemini
is not aliased to the separate Antigravity harness.

The shipped daemon is frozen against Python 3.12
(`Contents/Helpers/jrbar-core.app`), which satisfies the bounded T3 SQLite
observation's need for `Connection.setlimit` (3.11+). Other native providers
keep their existing identity, quota-authority, credential and consent
boundaries; no generic quota endpoint or ACP support is claimed for every
harness.

## Owner acceptance before a release

The source gates are `make fast` and `.venv/bin/python -m pytest tests -q`, plus
`cd app && swift build && swift test` for this window. What compilation cannot
tell you, and what still has to be checked by hand on the Mac:

- The installed app's Control Center: keyboard navigation and VoiceOver, reduced
  motion, increased contrast, every display edge for the compact rail, scaling,
  external displays, full-screen Spaces, Dock placement.
- With Input closed: real firmware discovery over USB and Bluetooth, every
  advertised control, aggregate and per-session lighting, bank changes, stable
  keys, sleep/wake, disconnect/reconnect, duplicate input suppression, and
  quitting promptly while the device is quiet. Unknown firmware layouts need an
  adapter update from captures, not an override of the refusal.
- Export the original keymap, apply a reviewed mapping, read it back, reconnect,
  verify activation, restore. Prove interrupted-transfer recovery on a scratch
  configuration before trusting it with a valuable one. Check competing-owner
  refusal without deliberately interleaving destructive writes.
- Each enabled provider against current accounts: fresh reading, offline and
  stale cache, expired credentials, account switching, a disabled provider, and
  no cross-account merging — then combinations, then software-only operation
  with the optional reference apps absent. Synthetic fixtures do not stand in
  for live providers.
- Existing SidePulse Pro/Dot LED output still works.

[FINAL-TESTING.md](FINAL-TESTING.md) is the full handoff and evidence boundary;
[PRODUCTION-RELEASE.md](PRODUCTION-RELEASE.md) is signing, notarization,
installation and the update feed.
