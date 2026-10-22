# Finding a setting

Settings has seven pages. The things most people touch are on the page. The
rest sit behind one **Advanced** row at the bottom of the page that holds
them. Search (⌘F in the Settings window) looks inside Advanced too, and
opens it when you pick a result.

| Page | What is on it | Behind Advanced |
| --- | --- | --- |
| **General** | Launch at login, the menu bar icon, power (keep the Mac awake), updates | Run Setup again, the beta channel, diagnostics and the core log, copy a report, export and import, reset a page |
| **Agents & Usage** | Which agents report in, sub-agent asks, which providers JR-Bar may ask for usage, menu bar meters, graph range, plan limits, quota alerts | How long an ask stays open, agent update checks, which transcripts are read, provider status pages, the Claude Code status line, usage hooks, kept history |
| **Alerts & Sounds** | The alerts profile, the finish banner, quiet hours, Focus, a sound for each moment, volume, the phone alert | Quiet-session banner, the calendar glow, escalation timing, battery lights, where sounds play, your own sounds, the webhook |
| **Devices & Lighting** | Each SidePulse and its firmware, the Pro and Dot, Creator Micro 2, Stream Deck, the Screen Bar, provider and state colours, blend, dimming, scenes | Calibration profiles, pulse range, Auto-dim, ambient cues |
| **Utilities & Toys** | The Menu Bar, Dock, Keep Awake, Agent Overview and Notch utilities, then the toys | None |
| **Shortcuts** | Global keys, app actions, quick toggles | `jrbar://` links, the command-line tool |
| **Remote** | Other Macs running JR-Bar, the local status endpoint, cloud ingest | None |

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

## Where the old pages went

Earlier builds had twelve pages. The names still work in links
(`jrbar://settings/usage`), in scripts and in the command palette, and land
on the right place.

| Old page | Now |
| --- | --- |
| Agents | Agents & Usage |
| Usage | Agents & Usage, below the agents |
| Notifications & Focus | Alerts & Sounds, apart from Power |
| Sounds | Alerts & Sounds, below the alerts |
| Devices & Screen Bar | Devices & Lighting |
| Lighting | Devices & Lighting, below the devices |
| Utilities | Utilities & Toys |
| Toys | Utilities & Toys, below the utilities |
| Remote | Remote, apart from the phone alert and the webhook, which are on Alerts & Sounds |
| Advanced | General, behind Advanced |
| Power (was on Notifications & Focus) | General |

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

Open Effect Studio under Devices & Lighting. Knight Rider, Scanner and
Pendulum have a **Background glow** slider. At 0%, the space behind the
moving head is dark. Raise it to keep a dim background. Assign the effect
to save the change. Pendulum's **Swing width** controls the head's width.
