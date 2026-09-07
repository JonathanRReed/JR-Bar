# JR-Bar Control Center

Source implementation: September 6, with final integration on September 7, 2026.
Portable regression checks have run. Final Mac, device, live-account and release
acceptance remain separate. Use `make final-test` from a clean `main` checkout;
[FINAL-TESTING.md](FINAL-TESTING.md) records the full handoff and evidence boundary.

## Start without hardware

Open **Control Center…** from JR-Bar's menu, or **Settings > Devices > Open
Control Center…**. Agent Browser and Usage Center retain their existing owners
and collectors. No Input, CodexBar, T3 installation, physical notch or accessory
is required for the workspace itself.

The workspace reserves stable slots for canonical provider/source/work identities.
It does not sort an existing key onto a different session during refresh. A session
that disappears keeps its slot as **Not observed**. **Pin / unpin** preserves a
slot across an explicit **Clear absent slots…** operation. Previous/next banks
handle overflow. Only opaque identity hashes are persisted, not project names,
paths, transcript text or credentials.

The optional **Compact rail** places the same session slots against the selected
display's left, right, top or bottom visible edge. State words, accessible labels
and tooltips accompany the compact marks. Closing the workspace leaves an enabled
rail visible; select **Compact rail: off** to remove it. Edge selection is saved
with the session board and restored when Control Center is next opened, including
after app restart. The rail does not independently open before the workspace;
display selection is resolved again rather than storing a stale screen identity.

Legacy observations without a canonical work identity remain in Agent Browser.
A visible session is not automatically controllable: navigation requires the
existing canonical action and navigation resolver. Unavailable navigation is
refused rather than launching a guessed terminal or emulating an approval.

## Connect a Creator Micro 2

Enable the existing Creator Micro master connection under **Settings > Devices**.
Approval remains bound to one stable serial number. USB is preferred only when
matching USB/Bluetooth records identify the same board unambiguously. Missing
serials, duplicate same-transport endpoints and conflicting replies are refused.

Close Input and other device controllers before taking over. JR-Bar does not
silently terminate them. RPC replies are not an ownership lock; concurrent
writers can still corrupt the firmware's single stream. Conflict detection is a
stop condition, not permission to continue writing through another controller.

With **Session keys and per-session lighting** off, the runtime can use temporary
whole-board `lights.preview` output without changing stock key mappings. With it
on, unmapped AG00–AG12 correspond to the current session bank; explicit saved
actions override navigation. Per-key colors require those AG keycodes in the
active firmware keymap and `v.oai.thstatus` support. Colors are device-wide, not
independent for each layer.

## Configure supported keys, encoders and joystick inputs

Choose **Inspect device setup…**. Inspection reads the complete bounded keymap;
it does not program it. Choose a stored profile/layer in the selection dialog,
then optionally include supported auxiliary mappings. The confirmation lists
exactly which firmware-generated keystrokes/macros will be unbound. Unknown
fields and unselected profiles/layers are preserved.

The base matrix maps 13 keys. The optional auxiliary transformation supports
existing three-entry encoder rows and joystick sector dictionaries carrying a
`k` keycode, subject to the firmware's 20 AG-slot budget. Unknown shapes and
oversized selections are refused, not guessed. Numeric encoder input labels do
not claim a physically verified direction. The profile/layer must still be
selected on the device: no undocumented profile-switch command is sent.

Before replacing `keymap.json`, JR-Bar saves and verifies the first private
backup, proves binary transfer on a uniquely named scratch file, rechecks device
identity/generation and the original bytes, then records recovery progress before
each destructive step. Reads/writes are offset-based and bounded. Device SHA-1
and complete byte readback establish **stored bytes**, not active firmware behavior.
Reconnect the board if its firmware has not activated the stored map.

After a successful apply the Control Center opens with **Input check: pause device
actions** checked. Press every key, turn/press the dial and exercise the joystick.
The observed logical input should appear before any action is enabled. Closing the
window does not resume actions. Explicitly uncheck Input check after inspection.

For continuous `v.oai.rad` input, enable **Enable analog joystick sectors**. Four
numbered sectors appear as mapping destinations 20–23. Each excursion emits at
most one action and must return to the dead zone before another. Confirm each
physical direction in Input check; angle zero/polarity are not assumed to mean
up/right. Existing discrete joystick key mappings can remain unchanged.

## Map actions and move settings

Under **Settings > Devices**, select the logical key, choose an action, then
**Save mapping**. Available actions include an installed app, a recorded shortcut
for that frontmost app, revealing the current ask, Agent Browser, Usage Center,
Control Center, bank changes, and a named macOS system Shortcut.

App shortcuts require Accessibility permission and the exact mapped application
to be frontmost. A system Shortcut runs by its user-entered exact name using
`/usr/bin/shortcuts` with fixed argv and no shell expansion. Its receipt distinguishes
queued, finished, failed, expired and timed out. Cancellation of the runner cannot
undo side effects an already-started system Shortcut has performed. Device events
and provider text never supply executable code or command arguments.

**Run selected mapping…** is the explicit virtual-input path. It asks for
confirmation and uses the same bounded dispatcher as physical input. Input check
also pauses virtual execution. Actions expire rather than replay after a delayed
UI, reconnect, remapping, bank change, or termination. Queue overload is counted.

**Import mappings…** reads one explicitly chosen JSON file, previews its actions,
and imports with actions disabled. **Export mappings…** writes the data-only host
mappings. Neither operation is a generic firmware file editor. A general-purpose
editor for arbitrary Input macros/smart actions is not implemented here.

## Recovery and uninstall

Use **Export original keymap…** to keep a separate copy before experimenting.
The first original remains in a private device-identity-scoped backup next to
integration settings; a separate `.recovery.json` records interrupted operations.
Do not delete either file while recovery is pending.

After **Recovery required**, use **Restore device keymap…**, not repeated Apply.
Apply is refused until recovery is resolved. If the original is already intact,
Restore verifies those bytes and clears the pending recovery without a device write.
Restore accepts only the original, JR-Bar's verified map, or a pending write's
recorded original/prefix. Unrelated later device edits cause refusal. A reconnect
starts a new transfer generation; it never resumes an old write automatically.

Before uninstalling JR-Bar, restore the original map and verify it on the board.
Then disable device actions and the Creator Micro master connection. AG keycodes
replace ordinary keystrokes and depend on a host handler; uninstalling the app
alone does not restore the firmware map.

## Provider compatibility

T3 remains an optional read-only SQLite source. The compatibility manifest records
a source review of `ea646c0834a3394ecb0be4a30c5d367e5a9002bd`; the historical maximum
**tested** version remains 0.0.33. A source review is not a new live compatibility
certification. Missing native thread IDs are accepted without using T3's own IDs
as native provider resume IDs. A ready/idle transport is not successful completion;
only an unambiguous explicit completed-turn projection supplies that outcome.
Gemini is no longer silently aliased to the separate Antigravity harness.

The portable package retains Python 3.10 syntax/import compatibility for Creator
Micro. Bounded T3 SQLite observation requires Python 3.11+ (`Connection.setlimit`);
the signed app's embedded runtime should satisfy this. Other native providers keep
their existing identity, quota-authority, credential and consent boundaries.
No generic quota endpoint or ACP/control support is claimed for every harness.

## Required owner acceptance before release

From a clean checkout of the merged revision, bootstrap the existing development
environment and run the real suites on the Mac:

```sh
./scripts/bootstrap-dev.sh
make fast
.venv/bin/python -m pytest -q tests/test_creator_micro_adapter.py \
  tests/test_creator_micro_wire_conformance.py tests/test_creator_micro_setup.py \
  tests/test_creator_micro_keymap.py tests/test_creator_micro_setup_rpc.py \
  tests/test_creator_micro_setup_controller.py tests/test_deck_control_center_contracts.py \
  tests/test_deck_input_dispatch.py tests/test_deck_control_settings.py \
  tests/test_deck_settings_pane.py tests/test_deck_settings_controller.py \
  tests/test_optional_integration_runtime.py tests/test_t3_compat.py
.venv/bin/python -m pytest tests -q
```

Check the installed native UI, keyboard navigation/VoiceOver, reduced motion and
contrast, all display edges, scaling, external displays, full-screen Spaces and
Dock placement. Source compilation cannot validate AppKit selectors or rendering.

With Input closed, verify the actual firmware's USB/Bluetooth discovery, every
advertised control, aggregate/per-session lighting, bank changes, stable keys,
sleep/wake, disconnect/reconnect, duplicate input suppression, and the ability to
quit promptly while the device is quiet. Retest existing SidePulse Pro/Dot output.
Unknown firmware layouts need an explicit adapter update based on captures, not
an override of the refusal.

Export the original keymap, apply a reviewed mapping, read back, reconnect, verify
activation, and restore. Prove interrupted-transfer recovery on a scratch/test
setup before relying on it for a valuable configuration. Check competing-owner
refusal without deliberately interleaving destructive keymap writes.

Verify each enabled provider with current accounts: fresh reading, offline/stale
cache, expired credentials, account switching, disabled provider and no cross-account
merging. Then verify combinations and software-only operation with the optional
reference apps absent. Do not infer live-provider success from synthetic fixtures.

Finally run the existing signing/notarization/installed-package/update/uninstall
release gates in `PRODUCTION-RELEASE.md`. No release/tag, firmware update, publication,
credential mutation or installer signing was performed as part of this source work.
