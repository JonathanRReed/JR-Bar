# Finding a setting

Settings groups controls by what they change. Less-used controls sit behind
Advanced on the relevant page. Search (⌘F) includes those controls and opens
their page when you choose a result.

| Page | Controls |
| --- | --- |
| General | Launch at login, menu bar icon, updates |
| Providers | Tracking, usage consent, panel and menu bar visibility, provider details |
| Alerts & Sounds | Notifications, quiet hours, Focus, sounds, phone alerts |
| Shortcuts | Global keys, app actions, quick toggles |
| Devices | SidePulse, PulseDot, Creator Micro 2, Screen Bar, lighting and firmware |
| Notch & Shelf | Island, media, shelf, Calendar and Reminders |
| Utilities & Toys | Menu Bar, Dock, Keep Awake, Agent Overview, Fold, Aquarium, Notch Buddy and Confetti |
| Remote | Other Macs, the local status endpoint, Stream Deck access and cloud ingest |
| Privacy | Transcripts, presence, history and optional network requests |
| Integrations | Connection status, compatible apps and system access, with links to their controls |
| Advanced | Setup, release channel, diagnostics, export, import and reset |

The meter styles show one column for each provider with a usage window that
is tracked and selected under Providers > Menu bar. They show at most six
providers in the saved provider order, then an overflow count. The shared
`StatusIconRenderer.maxMeters` constant sets this limit for the menu bar,
Settings preview and Setup preview. A provider without a quota window has no
column. For multiple accounts, JR-Bar uses the default account when it has
a usage window, otherwise the first measured account.

Render with hands the selected utility to another installed app. JR-Bar
parks its own renderer and opens that app; it does not send its island,
previews or agents to the other app. Missing apps say Not installed and
cannot be selected. Choose JR-Bar to bring its renderer back.

Integrations reads existing connection facts. A disabled device says Off;
it does not get probed to fill this page. Firmware is read once on page open
for connected, enabled hardware, or says Firmware not read. Stream Deck's Serving
status confirms the loopback endpoint, not a connected physical deck.

## Utility and toy controls

In Settings > Utilities & Toys:

- **Menu Bar:** read the banner at the top of the card before changing
  hiding. "Enabled, hiding has not been checked" means the divider has not been
  confirmed. "Showing the hidden section" means items are temporarily
  revealed. "Enabled, checking the divider" means a fresh check is pending.
  Recovery warnings explain when hiding could not be confirmed after the
  bar changed. Show everything reveals all items; Hide my picks
  again restores your choices. A warning also offers Turn Menu Bar off.
  Under Overrides, Search name lets you find an item by a name you choose,
  such as "Work VPN". Its original app name and title remain visible and
  searchable. Names stay in JR-Bar's local settings and are included when
  you export those settings. Items without a unique Accessibility identifier
  cannot keep a search name safely. Clear the field to remove a name.
- **Keep Awake:** enter 1 to 1,440 minutes under Custom duration and click
  Start for a one-time session. This replaces the current manual session
  without saving a preset. Add preset keeps the duration in the Awake menus.
  A hold keeps the Mac running and lets the display sleep. With the lid
  closed the screen goes off while the Mac stays on. Keep the display on
  (for your sessions) and Keep display awake (for the agents) hold the
  screen too. Both are off by default, and 0.10.1 turns them off once for
  everyone, so turn them back on if you want them. Five minutes before a
  timed session ends, one notice says so, and +30 min carries on. Turn off
  Heads-up before it ends if you'd rather not get it. Focus and quiet hours
  hold the notice the way they hold other banners. The cup's steam thins as
  the time runs out. If a hold doesn't take, the card says "Couldn't hold
  the Mac awake" and offers Try again.
- **Dock:** Never preview hides an app's Dock previews. Never switch to
  excludes it from JR-Bar's ⌥⇥ window switcher and ⌘⇥ app switcher. The two
  lists are separate; excluding an app from a switcher leaves its previews
  available.
- **Aquarium:** choose Live or Still under Motion, or use the tank's
  play/pause button. Still holds the scene while session status, rewards and
  feeding keep updating. The fish button opens a menu of sessions, workers
  and residents. Pick one to open its inspector without chasing a fish.
- **Agent Overview:** a failed Reply stays open with its error below the
  editor and your draft intact. If the send is unconfirmed, the reply may
  have landed. Check the session before answering again.

On the Notch card's Shelf page, right-click a file or stack and choose Clear
Shelf when more than one entry is present. This removes shelf references,
leaving the files where they are. Undo Clear Shelf restores the last cleared
items until you add a new file or quit JR-Bar. Shelf moves that finish after
a clear also update those cleared references.

The Now page shows a finished timer first, otherwise the nearest running
timer, or a paused timer if none are running. Use Pause, Resume or Dismiss
beside it, or click its label to open all timers on Shelf.

When a waiting session is named in the Now page's header, its row stays
below with the available answer and detail controls. Open the details to
read the request; opening them sends no answer.

## Older links

Earlier page names still work in links such as `jrbar://settings/usage`,
scripts and the command palette. Agents and Usage open Providers; Lighting
opens Devices; Toys opens Utilities & Toys; Notifications opens Alerts &
Sounds. Notch has its own Notch & Shelf page.

## Menu bar item shortcuts

In Settings > Shortcuts > Menu bar, choose Add item, select an item, then
record a shortcut. Choosing an item alone saves nothing. No item has a default
key. Accessibility permission and a running Menu Bar utility are needed.

JR-Bar saves the app's bundle identifier and the item's Accessibility
identifier. When an app has no item identifier, Only item means its one menu
bar item. That shortcut pauses if the app later exposes more than one item.
The item's title is only its display name. Changing its title or moving it
never changes which item the key selects.

Each saved row shows whether its item is ready, missing, ambiguous, disabled,
or refused. A missing or ambiguous item keeps its saved assignment, but its
key is released until the item returns uniquely. Returning items never open
on their own. Refresh items to check again.

Record a new key to change it. The switch disables a shortcut while keeping
its assignment. Clear or Remove item shortcut deletes the assignment. When
another JR-Bar shortcut owns the key, Use Here clears the old assignment and
moves the key to this row. Two enabled item shortcuts with the same key both
pause until you change or remove one.

Item shortcuts stay the same when you change menu bar profiles. They travel
with Utilities in settings exports and imports. At each key press, JR-Bar
checks the running owner and its current menu bar items again. If the exact
item is gone or its app refuses the press, the row reports it and JR-Bar leaves
the other items alone.

## Sweep background

Open Studio from **Settings › Devices › Open Studio**. Knight Rider, Scanner and
Pendulum have a **Background glow** slider. At 0%, the space behind the
moving head is dark. Raise it to keep a dim background. Assign the effect
to save the change. Pendulum's **Swing width** controls the head's width.
