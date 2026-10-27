# Recovery

Start with the visible state. JR-Bar keeps failures honest instead of turning
an old reading into a fresh one.

## Monitor offline

Quit JR-Bar and open the installed app again. If the panel still says the
monitor is offline, run:

```sh
jrbar doctor
```

The report names the daemon build and any failed checks. If the command is not
installed, open **Settings > Shortcuts > Advanced > Command line** and install its link
first. Reinstall the app only after the same installed copy still fails to
start its daemon.

## Quota is stale

Open the Usage Center and read the source note on the affected provider.
`jrbar providers status` gives the same state in the terminal.

- For Codex local evidence, finish one Codex prompt so its rollout records a
  new reading.
- For a provider that says its sign-in is stale or required, press **Fix
  sign-in** on its card. For Claude it asks Claude Code to renew its own
  sign-in; for Grok, Codex and OpenCode it opens your terminal on the CLI's own
  login. [What it does for each provider](providers.md#fix-sign-in).
- A rate-limited provider needs time. JR-Bar backs off and retries later.

JR-Bar keeps a last good reading only when it can prove the account is the
same. An account switch may leave the card empty until the new account returns
a fresh reading.

## Hooks are missing

Open **Settings > Providers** and install or reinstall the affected provider.
Then run:

```sh
jrbar hooks doctor
```

The report shows the command in each provider config and whether JR-Bar's
sockets answer. Upgrades refresh only detector-proven managed hooks. A custom
or ambiguous hook is left alone for you to review.

## A permission is missing

Open JR-Bar's setup or the relevant feature settings. The permission row names
what the feature needs and opens the matching System Settings page when macOS
allows it. Grant only the features you want.

If a permission was granted to a development build, the installed app may ask
again. macOS ties grants to the signed app. The full list is in the
[permissions table](../../README.md#permissions).

## My menu bar icon is missing

JR-Bar's icon is the menu bar item, and hiding is the icon's own blank
stretch to its left, so hiding never takes the icon away. On a bar too full
for it, macOS can park the icon; the Menu Bar card says so. If you cannot find
it, work down this list.

1. **Open JR-Bar.app again** (Finder, Spotlight, or `open -a JR-Bar`).
   Opening the app while it runs brings up Settings, so you never need the
   icon to get in. Opening it right after quitting waits up to ten seconds for
   the old copy to let go of `~/.local/state/jrbar/app.lock`.
2. **Check the icon style.** In **Settings > General > Menu bar > Menu bar
   icon**, the **No icon** style draws nothing on purpose. Pick another.
3. **Go to the Menu Bar card.** The link `jrbar://settings/utilities` opens
   Settings on the Utilities page (`open jrbar://settings/utilities` from a
   shell, or `jrbar open settings/utilities`). The card's first line says
   whether hiding works and, when it does not, why, with the one-click fix.
   The icon having no room on a crowded bar is one of the cases it names.
4. **Press Show everything.** It puts every item back on the bar now, even
   over Hide all, and keeps your picks. **Hide my picks again** undoes it.
   **Turn Menu Bar off** is beside every warning; with the utility off,
   every item shows exactly as macOS draws it.
5. **Quit JR-Bar and open it again.** At launch JR-Bar clears any saved
   "hidden" placement macOS holds for its item and recreates the item if it
   cannot find it.

To see what the icon decided, look at the log (a few seconds of lag is normal):

```sh
/usr/bin/log show --last 10m --predicate 'process == "JR-Bar" AND subsystem == "devin.jrbar" AND category == "status-item"'
/usr/bin/log show --last 10m --predicate 'process == "JR-Bar" AND subsystem == "devin.jrbar" AND category == "instance"'
/usr/bin/log show --last 10m --predicate 'process == "JR-Bar" AND subsystem == "devin.jrbar" AND category == "menubar"'
```

- `status-item` lines say the item was hidden and shown again, that saved
  placement was cleared, or that it was recreated and why.
- `instance` lines say a second copy yielded ("already running") or that the
  single-instance lock was unavailable.
- `menubar` lines say what the divider did and why:
  - `engine: divider — positionsHold` once at start: position is the
    setting.
  - `bar: ...` when the icon was checked after the bar re-formed (a wake, a
    display change), re-seated once, or left alone because it was still
    wrong.
  - `drag: ...` for a ⌘-drag: the bar held still for the press, and what
    moved when it settled.
  - `record: ...` when the bar's positions were written to the record.
  - `reveal: ...` which gesture revealed the hidden items (a hover, a click,
    a scroll, a hotkey, a rule) and when they were put away again.
  - `rule: ...` when a rule changed the keep-awake hold.

## Hiding is stuck

Which apps hide is where they stand on the bar: everything left of the
JR-Bar icon is hidden, everything right of it stays, and you hold ⌘ and drag
an item across the icon to change it. If the bar looks wrong:

- Read the card's first line on the Menu Bar card of **Settings >
  Utilities**. It names the cause: another manager (Bartender, Ice, Hidden
  Bar and others) is also hiding items, Accessibility is off, or macOS has
  no room for the icon on a crowded bar. Each has its button or its fix.
- **Show everything** brings every item back and keeps your picks; its menu
  also offers 5 minutes or an hour. **Turn Menu Bar off** stops all hiding.
- The `menubar` log lines above name what the divider decided.
- Without a mouse, turn on the Item Bar hotkey ⌘⌥B on the card (it is off
  until you do) to open the hidden apps from the keyboard.

If the card itself cannot be reached, quit JR-Bar and, in
`~/.local/state/jrbar/app-state.json`, set `utilities` > `menuBar` >
`enabled` to `false`. That is the last resort; it keeps every other setting.

## The strip is the wrong colour

The panel's **Why this light** row names what the strip and the Screen Bar
are doing and why; hover it for the programs and settings behind it. Then
check, in this order:

- A quiet period changes the light on purpose. `jrbar status` shows it, and
  `jrbar quiet off` ends it.
- **Settings > Devices > Brightness > Maximum brightness** caps every light.
- **Settings > Devices** has a **Colour calibration** row per
  device and for the Screen Bar. A device that is not "Uncalibrated" is
  being tinted by its gains; open **Calibrate...** and choose **Reset to
  default**.
- Amber is an open ask and red is a failed session. A sub-agent's ask only
  lights when **Sub-agent asks** is on.

## Confetti did not fire

Confetti plays only while the Confetti toy is on (**Settings > Utilities & Toys**). The
card's **Test burst** fires one on demand; if that works, a trigger or a
hush kept the real one back.

- The trigger row must be on: **Weekly reset**, **Session completed**,
  **All caught up**, **Codex banked credits** or **Milestones**. A reset the
  app notices late (hours after its boundary, or one that refilled by under
  50 points) still counts. A reset that happened while the app was away is
  offered again when it reconnects, for 24 hours, and celebrates once.
- **Quiet the toys during Focus, quiet hours and calls**: while JR-Bar is
  quiet, a Focus is on, a call has the mic or camera, or a full-screen app
  owns every screen, a burst waits. Anything held for over half an hour is
  let go.
- Every verdict is logged as `confetti: <what> <delivered|held|dropped|expired>
  (<reason>)`, and a quota reset's verdict is also written on the reset
  event in `~/.local/state/jrbar/provider-reset-events.json`. The line is
  at info level, so ask the log for it:

```sh
/usr/bin/log show --info --last 10m --predicate 'process == "JR-Bar" AND subsystem == "devin.jrbar" AND category == "confetti"'
```

Reasons you may see are `presented`, `toy_off`, `already_celebrated`, `stale`
(too old to celebrate), `trigger_off`, `no_lane`, `replaced`, `after_hold`,
and the hush that held it: `call`, `focus`, `quiet` or `fullscreen`.

## Moving or restoring settings

**Settings > Advanced > Transfer** exports the monitor's settings, devices,
Utilities, Toys, shortcuts and sounds as one private JSON file, and imports
one with a checklist of what to take. An import never turns on a request that
leaves the Mac (remote machines, cloud ingest, status feeds, update checks,
the local status endpoint, an escalation webhook), a hook program, a phone
link or a permission prompt. It names each one it left off, and you turn them
on by hand. An export does not carry the webhook URL or hook programs.

## A saved file could not be read

JR-Bar keeps your own choices (effect assignments, pins and snoozes,
acknowledged requests, cleared completions) in small files under
`~/.local/state/jrbar`. The app's own state (`app-state.json` and the
Aquarium's `aquarium-save.json`) lives there too, and one it cannot read is
kept beside it as a copy named like `app-state.recovery-<id>.json`. When one of them cannot be read, JR-Bar does not
overwrite it. It moves the file aside as `<name>.corrupt-<date and time>`
(for example `effect-assignments.json.corrupt-20260901T120000Z`) and starts
that list empty. If only some rows were damaged, it keeps the good rows and
leaves a copy of the original beside them. The three newest copies of each
file are kept, and each is private to you. The Core log on **Settings >
Advanced** has one line saying which file was set aside.

To get a file back, quit JR-Bar, copy the `.corrupt-` file over the original
name, and open JR-Bar again. If it is still unreadable it will be set aside
again.

Settings follow the same rule. The monitor's settings live in
`~/.config/jrbar/settings.json` (or under `$XDG_CONFIG_HOME/jrbar`). A
`settings.json` that cannot be read is set aside as
`settings.json.corrupt-<date and time>`, with the same three-newest rule, and
the next save writes a fresh one.

If `settings.json` is changed outside JR-Bar while it runs (by hand, by a
restore, or by `jrbar battery configure`), JR-Bar notices the next time it
saves a setting. If the file is whole, JR-Bar takes it as it is, shows it in
Settings, and keeps the settings it held as `settings.json.replaced` (one
backup, the latest replacement). A file that does not parse is not taken: JR-Bar
waits for the next refresh in case your editor is still saving, and if the file
has not changed by then it sets it aside as `settings.json.corrupt-<date and
time>` and writes the settings it holds out again. Until a setting is saved, an
edit made while JR-Bar runs is not seen.

## A protected setting was changed outside JR-Bar

A few settings decide whether JR-Bar answers an agent from `jrbar serve`, sends
a webhook, takes cloud ingest, talks to a remote Mac, runs a usage hook or
reads a provider. They are **sealed**: JR-Bar signs them with a key it keeps in
your Keychain, and a program running as you cannot read that key. Editing one
of them in `~/.config/jrbar/settings.json` (by hand, by a script, by anything an
agent ran) changes nothing. JR-Bar uses the values it already had, writes them
back over the file within a second, keeps the file it found as
`settings.json.rejected`, and shows this at the top of Settings:

> A protected setting was changed outside JR-Bar and was ignored.

- **You did not make that change:** press **Discard the change**, or leave it.
  Nothing it asked for happened. Look at what ran as you: the file
  `settings.json.rejected` is what it wrote.
- **You made it by hand and want it:** press **Keep the change**. JR-Bar checks
  the values the way it checks anything you set, applies them and seals them.
  Or just set it in Settings, which is the same thing. The ignored values are
  held while JR-Bar runs; after a restart they come back from
  `settings.json.rejected` as long as that file is still there.
- **Every other setting** still follows an outside edit exactly as before.

**Protected settings are not sealed (Keychain unavailable)** means JR-Bar could
not get its key: the Keychain was locked, or you declined its prompt, or this is
a development build the key does not trust. JR-Bar runs as it always did and
never blocks, never asks twice on its own, and tells you. Unlock the Keychain
and press **Try again** (JR-Bar may ask once; choose **Always Allow**). While
it is unsealed a program running as you can change those settings by editing
the file. A protected setting you changed while it was unsealed may show up as
ignored the next time the key is back; press **Keep the change** if it is
yours.

**Reset protection** (Settings > Advanced > Protected settings) seals the
protected settings as they are in JR-Bar right now and drops any ignored edit.
To rotate the key itself, quit JR-Bar, delete the Keychain item named
**JR-Bar settings seal** in Keychain Access, and open JR-Bar: it makes a new
key and seals the current settings with it, with nothing lost.

## A firmware update did not finish

The device applies an update only from a complete, valid file, so a failed
update leaves it on its old firmware. Read the result in the sheet, or run
`jrbar firmware version`.

- **"Not confirmed" / the drive did not come back:** unplug the device and plug
  it in again, then check its firmware. The lights stay still until it is back.
- **"Still reports the old version":** reconnect it and check again; if it is
  still old, press **Download and update** again.
- **"No free directory entry":** the drive is full of files that are not
  JR-Bar's to remove (it names them). Delete the ones you do not need in
  Finder, eject and reconnect the device, and try again.
- **The lights look off after an update:** a Pro on firmware 1.1.0 balances
  colour itself; re-run colour calibration in **Settings > Devices**.

[The whole procedure](firmware.md).
