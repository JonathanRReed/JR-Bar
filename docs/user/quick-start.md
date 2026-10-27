# Quick start

JR-Bar becomes useful as soon as one provider sends it session events. No
hardware is required.

1. Open JR-Bar and choose **Settings > Providers**.
2. Find a provider already installed on this Mac, then click **Install** for
   its hook.
3. Start a new prompt in that provider. The session should appear in the
   panel after its first event.
4. Click the status item to open the panel. A real permission or input request
   stays pinned at the top with **Approve** and **Deny**. JR-Bar never answers
   one on its own. To see one before an agent asks, press **Try it** on the
   last Setup step, or **Settings > Providers > Asks > Show a demo ask**. It is
   a violet card marked **DEMO** that is made inside the app: nothing is sent
   to an agent, nothing is recorded, and **Approve**, **Deny** and **Put
   Away** only take it down.
5. Open the Usage Center to see the quota windows the provider actually
   reports. A missing window stays missing, and an old reading is marked
   stale.

An ask that shows one line can be opened. Click the small chevron next to its
command to read the whole command (up to 2,000 characters, secret-looking
tokens hidden), a file edit's size such as "edit: 2 files, +14/-3", or the plan
an agent wants approved. It never opens on its own, and opening it answers
nothing. A plan is approved in the agent's own session, so its card offers
**Answer in the session**.

To jump to the ask that has waited longest from any app, record a key for
**Show the waiting ask** in **Settings > Shortcuts > App actions**. It has no
key until you record one (the app keeps it in its defaults as
`hotkeyChord.action.revealAsk`; clearing the recorder removes it). It opens the notch card when the notch is JR-Bar's,
else the panel, and never answers.

The same key is the keyboard's way into an ask that is showing at the notch.
While the island holds an ask with Deny, Approve or Open on it, the key hands
the island the keyboard instead of opening the card. Nothing is selected yet:
Tab or an arrow key puts a white ring on the first verb (Shift-Tab or Left on
the last), the arrows and Tab move it, and Return or Space presses the verb the
ring is on. Esc lets the keyboard go and answers nothing, and the island lets
it go by itself after 15 s without a key, when the ask is answered somewhere
else, or when you click away. Pressing Return before you have moved the ring
does nothing. With VoiceOver, the ask is one item (who needs you, and what
they asked) and each verb is an action on it as well as a button.

If an ask goes unanswered, it steps up: its light brightens after 30 s and
the menu-bar icon pulses after 2 min. By default that is where it stops. To
add a chime that repeats every 30 s from 5 min on, or a Take over card that
grows out of the notch, pick Chime or Take over in **Settings >
Alerts & Sounds > Advanced > Escalation > Loudest stage**. The three delays are in
the same group. A failed session is different: it turns the light red and
shows one banner with a short sound. A failure is not an ask and never
escalates.

How loud JR-Bar is about the rest is one choice: **Settings > Alerts & Sounds >
Alerts profile**.

- **Quiet** is asks only: no finish banner, no quota alerts, and an ignored
  ask stays on the light.
- **Balanced** is the default for a new install. A banner when a session
  finishes ("jr-bar finished in 4m 12s", then the first line of what the agent
  said last) and when a quota runs low, reset or crosses its threshold. An
  ignored ask reaches the menu-bar pulse.
- **Loud** adds the chime for an ignored ask and one banner when a session
  that is still running has said nothing for ten minutes.

The switches below the picker stay yours. When they differ from all three it
reads **Custom**. A profile only changes those local switches; it never turns
on a webhook, a provider request or anything that leaves the Mac. If you had
already turned a banner on or off before this picker existed, JR-Bar keeps
that choice. A finish banner is skipped while that session's terminal is
already in front.

To hear about one run without turning banners on for every run, hover a
working row and click its bell (or choose **Notify When Done** from its menu).
You get one banner when that run ends, then the bell turns itself off. A row
that has sent nothing for ten minutes, with no tool call running, shows
"quiet 12m" in amber; a long build does not count.

If you use the Screen Bar, hover over the band to peek at its card. Click the
band to pin the card. Click the session mark on the left wing to open the
focused session.

When the Notch card is open, clicking its menu wing opens the hidden-item
popup without folding the card. Moving into the popup keeps the card open.
Escape closes the menu first. On a short display, the menu moves up or
scrolls to keep its controls reachable.

Menu Bar is optional too. **Settings > Utilities & Toys > Menu Bar** hides the apps
you pick behind JR-Bar's icon: hold ⌘ and drag an app left of the icon to hide
it, right of it to show it, and nothing is hidden until you do. The card's first line says whether hiding works and
why not, and **Show everything** puts every item back at any time. If the bar
ever looks wrong, [recovery](recovery.md#my-menu-bar-icon-is-missing) starts
there.

Optional hardware uses the same light program, but it is a separate check.
A working Screen Bar does not prove a SidePulse strip or Creator Micro 2 has
been tested. See [Control Center](../CONTROL-CENTER.md) for the pad and the
[README](../../README.md#hardware-optional) for the lights.

Useful checks:

```sh
jrbar status
jrbar usage
jrbar hooks doctor
jrbar doctor
```

The command is optional. Install its link from **Settings > Shortcuts >
Command line**. If something remains offline, use [recovery](recovery.md).
