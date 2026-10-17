# Menu bar managers and the Ice model on macOS 27 (2026-10-07)

Why this exists: the person asked for "the Ice feel". Move an item left of
the icon and it disappears; move it right and it comes back. JR-Bar's
macOS 27 engine hides a list of apps with the system's assessment-mode
assertion, so a hidden app is not drawn and cannot be dragged back. This
note records what the other managers do, what holds on this Mac, and what
the Menu Bar utility adopted. Facts about this Mac (notched MacBook Pro,
macOS 27.x) are the ones measured earlier and written in
[UTILITIES.md](../../UTILITIES.md); the rest is from public sources read on
2026-10-07. Nothing here was copied: Ice, Thaw and Pelmet are GPL-3.0, so
JR-Bar studied their descriptions and measurements and wrote its own code.

## What each project does

| Project (licence, commit read) | Hiding mechanism | On macOS 26 and 27 |
| --- | --- | --- |
| Ice, jordanbaird (GPL-3.0, `11edd391`, 2025-09-20; the repo has had no commit since) | Its own status items are dividers. Position is the section: items left of the hidden divider are hidden. A collapsed divider is set to 10 000 pt so everything left of it falls off the row. A third divider makes "always hidden". Clicking a hidden item moves it into view with a synthetic ⌘-drag, clicks it, and returns it. | Broke on Tahoe point releases (hidden items dumped into Always Hidden, empty layout editor) and then on 27, where clicking the icon does nothing (issue 954, open, 42 comments). PR 995 (open) restores hiding with the assertion. |
| Thaw, thaw-app (GPL-3.0, `897b6225`, 2026-10-06) | The 2.x line is an Ice fork with its own layout engine and a synthetic ⌘-drag fallback. The 3.0 line, whose source is private, hides with the assessment-mode allowlist and keeps a saved layout per app. | Documents the limits: apps hide as a whole, Focus and the camera indicator vanish while anything is hidden, the manager's own icon can be parked. |
| Pelmet, fif7y (GPL-3.0, `3f757c96`, 2026-10-05) | macOS 27 only. A chevron divider records where items were moved; hiding is the allowlist. Layout edits are a draft applied in one pass. Reveal by hover, click or hotkey; clicks on hidden items go through Accessibility. | Screen Recording is optional. |
| Stash, brentc22 (MIT, `10596c43`) and Ellipsis, ronny (Apache-2.0, `be2df6a7`) | Allowlist. Ellipsis has an optional Accessibility mode where ⌘-dragging an item left of its icon hides it. On a notch Mac it lists hidden apps in a bar under the menu bar because the shown set may not fit. | Same limits as Thaw. |
| Hidden Bar, dwarvesf (MIT, `47937b9d`, 2026-09-19) | A separator status item inflated to about twice the screen width, capped at 10 000 pt, plus an optional second separator. | Its own notes say items under the notch cannot be revealed and that 27 breaks the inflation. The newest commit adds a "notch overflow" bar below the menu bar. |
| SaneBar (MIT, `2311b237`) and Dozer (MPL-2.0, `b0540378`, 2022) | Length trick. | SaneBar's author stepped back because "27 breaks every manager"; a synthetic ⌘-drag that crosses the notch is silently dropped. Dozer is unmaintained. |
| Bartender (closed) | Version 6 for Tahoe, 7 beta for 27. Versions 6 and 7 keep items around the notch from jiggling and pop what overflows the notch into a bar. 7 stops moving the mouse and shows a Bartender Bar. | Whether 7 uses the allowlist is not published. |

## The finding that matters

On macOS 27 the bar is one window the system's agent draws, so the old
tricks that enumerate or move per-item windows are gone. The length trick
is not entirely dead, though. Issue 954 measured that a status item wider
than half the screen is dropped instead of clamped (848 pt pushes on a
1728 pt display, 849 pt does nothing), which is why a 10 000 pt separator
does nothing. A short one still pushes, and this Mac agrees: a 250 pt item
pushes the items left of it into the system's own overflow with no holes,
and a 3 000 pt item is parked itself. So the Ice divider works here, with
two honest conditions: it must be shorter than half the screen and it must
fit in the visible run right of the notch.

Everything else the field learned also holds here: apps hide whole, the
agent reorders items on its own, concealed items keep reporting stale
frames in Accessibility, clicks on the clock and Wi-Fi need a lift and a
replay under an assertion, and a manager's own icon can be parked.

## What JR-Bar adopted

- **Ice's mental model, with the real status item as the divider.** Items
  left of the icon are hidden, items right of it are shown, and the person
  ⌘-drags across it. Position is the setting, so there is no list to keep
  in step. This is the divider (spacer) engine JR-Bar already had.
- **A spacer capped under half the screen.** The divider's length never
  reaches the width where the system drops the item.
- **Hover, click, scroll and hotkey reveal, auto-rehide on a clock, and a
  below-the-bar panel for what does not fit.** Ice, Hidden Bar's notch bar,
  Ellipsis and Bartender all arrived at the panel for the same reason: on
  a notch Mac the run right of the notch cannot show everything at once.
  JR-Bar's Item Bar is that panel and now opens by itself when a reveal
  leaves hidden items parked.
- **The assertion as the second engine,** kept for what the divider cannot
  do: a saved list of hidden apps (from before this model) whose items are
  not yet left of the icon, and a bar so crowded that macOS parks the icon
  itself. The choice is automatic and explained on the card; Advanced can
  pin either engine.
- **A saved list moves over only when positions say the same thing.** The
  switch waits until every listed app has been seen left of the real icon
  while nothing is asserted, or the person presses Switch now, which says
  what will show. Under the divider the list follows the bar's positions,
  so a fall back to macOS hides the same apps.
- **Honest labelling.** Apps hide whole; Apple's own items stay; JR-Bar
  says it cannot move another app's icon and points at the ⌘-drag.

## What JR-Bar rejected

- Synthetic ⌘-drags and window-id teleports (Ice, Thaw 2.x). They move the
  person's real pointer and are dropped across the notch.
- A second status item for "always hidden". Two of ours swap sides on every
  reflow (measured 2026-09-15), so "always hidden" stays an override.
- Treating an item's physical order as its section while the assertion
  runs. The agent reorders, so under that engine the saved list stays the
  record, and positions are read only while nothing is asserted.
- Anything that needs Screen Recording to work. App icons stand in.

## Sources

- <https://github.com/jordanbaird/Ice>, issue 954 and pull request 995
- <https://github.com/thaw-app/Thaw>
- <https://github.com/fif7y/pelmet>
- <https://github.com/brentc22/stash>
- <https://github.com/ronny/ellipsis>
- <https://github.com/dwarvesf/hidden>
- <https://github.com/sane-apps/SaneBar>
- <https://www.macbartender.com/goldengate/releases/>
