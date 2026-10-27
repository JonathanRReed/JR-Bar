# Menu bar hiding verification

This check is pending against an installed build containing this branch. Passing
source tests does not establish that macOS draws or hides the items correctly.

## Findings on 3306

The worktree started at `82f432f6`. Read-only inspection on October 26 found
installed app PID 33524, build 3306, on macOS 27.2, build `26B5112a`.
[The earlier OS correction](../archive/AUDIT-2026-09-16.md) explains why the older
notes call this machine's composited menu bar "macOS 26".

- The diagnostic's unchecked state is `MenuBarWakeRecovery.Verdict.idle`.
  Launch did not arm recovery. Host attachment and style changes did not arm it
  either. Display and wake events did. The installed app logged display checks
  at 20:38, after the earlier diagnostic capture. The claim that no check ever
  ran during the entire 3306 process lifetime would be incorrect.
- An incomplete inventory returned before the recovery deadline, and a missing
  boundary returned before assessment. Either could leave a check unfinished.
  The scheduled checks reconciled cached listings instead of requesting fresh
  ones. A scan newer than the last width write could also predate the event.
  Each event now requires a newer scan. Recovery verdict changes also had no
  direct observation notification.
- The eight suggestions are Adobe Creative Cloud, Claude, cmux, Ollama,
  Wispr Flow, ChatGPT, Tailscale, and Dropover. Their bundle identifiers remain
  in `curation.dividerSuggestions`. The pre-install and startup documents for
  3306 carry the same eight, as do historical recovery documents. Seven also
  remain in `concealedApps`; cmux survives as a suggestion. The suggestion list is deliberately independent of the
  positional record, which changes as items move or disappear.
- Commit `2606ae02` converted the saved list into placement suggestions. The
  divider ignores that list. An older migration could clear `concealedApps`
  before creating suggestions. A document without a `curation` block could
  also decode as already migrated. Neither defect proves that 3306 erased
  these eight choices, which are still present.
- AX reported JR-Bar's item at `[901, 4.5, 173, 24]` in Quartz coordinates.
  The native overflow control was `[869.5, 1, 18, 30]`. The first reading put
  Battery at x=1089, Wi-Fi at 1131, Passwords at 1160, Audio and Video Controls
  at 1212, Weather at 1245, Control Center at 1321, and Clock at 1360.
  No third-party item was reported left of JR-Bar. The screenshot agreed
  about JR-Bar, overflow, and the visible system items. A blue circular icon
  was also visible left of overflow; AX did not identify its owner. AX did
  not identify the contents of native overflow, so zero listed hidden items does not
  establish that the old choices are visible or applied.

A list of bundle identifiers cannot position those items with the divider.
JR-Bar must keep the choices and explain what is unknown. It must not restore
an assertion, cover their slots, write system preferences, or synthesize drags.

## Capture the baseline

Use an installed candidate prepared by the release owner. Do not launch the
SwiftPM executable beside the installed app. Keep the existing rollback copy.
Do not toggle hardware, answer agent asks, or change device settings.

Run these commands from this worktree. The inspection script reads AX only;
its frames can be stale and are not a visibility verdict. Errors are recorded
rather than treated as absent items.

```sh
umask 077
jrbar_menu_receipts="$(mktemp -d /tmp/jrbar-menu-check.XXXXXX)"
git rev-parse HEAD > "$jrbar_menu_receipts/source.txt"
plutil -extract CFBundleVersion raw -o - "$HOME/Applications/JR-Bar.app/Contents/Info.plist" > "$jrbar_menu_receipts/build.txt"
sw_vers > "$jrbar_menu_receipts/os.txt"
defaults read com.jonathanreed.jrbar > "$jrbar_menu_receipts/preferences-before.txt"
cp "$HOME/.local/state/jrbar/app-state.json" "$jrbar_menu_receipts/app-state-before.json"
swift scripts/inspect-menu-bar.swift > "$jrbar_menu_receipts/items-before.json"
screencapture -x "$jrbar_menu_receipts/bar-before.png"
/usr/bin/log show --style compact --last 5m --info --predicate 'process == "JR-Bar" AND category == "menubar"' > "$jrbar_menu_receipts/check-before.log"
```

Do not publish the raw app-state document. Keep the receipts private. Record
the candidate's packaging receipt and source commit beside its build number.
Stop if Accessibility is unavailable; do not grant it through an automated
system-preference change.

## Verify launch and the saved choices

1. Open JR-Bar Settings through the visible icon. Open Utilities & Toys,
   then Menu Bar. Capture the whole page and the menu bar.
2. Read the banner, inventory notice, hidden count, saved suggestions, and
   What JR-Bar sees below Your bar. Capture each part, scrolling when necessary.
3. Allow at most 45 seconds for each check. The launch log must contain
   `the divider started`, followed by `divider check: clear` or `recovered`
   when geometry is verified. A partial
   listing or missing boundary must end as `unverified`, not remain checking
   beyond the bounded check. A stuck check must report its reason and stop
   after one re-seat. An unverified or stuck result fails live acceptance.
4. Compare `concealedApps`, `curation.dividerSuggestions`, reveal style,
   profiles, sections, and dismissed hints with the baseline. An already
   migrated document must keep its choices and dismissals. Missing items must
   say their visibility is unverified. A zero count must say "No hidden items
   reported" and keep Show everything available. Missing items must not be
   called visible merely because AX omitted them.
5. Open the native overflow control once. Capture its contents and identify
   which saved picks are present. Close it without selecting an app. Record
   running, absent, reported, and visibly hidden separately for each pick.

## Verify placement and every style

1. Establish a real hidden section only through the owner's chosen layout.
   If necessary, Jonathan physically Command-drags a chosen item left of
   JR-Bar, or JR-Bar right of the intended hidden run. Record the before and
   after order. Do not synthesize a drag, move the pointer from a script, or
   write Preferred Position. Do not dismiss saved picks to make the test pass.
2. After the drop settles, the log must name `a menu bar item was placed` and
   finish with a verdict. Capture the reported boundary frame, assigned width,
   fit edge, section counts, and actual bar. Verify the left-side items are
   absent from the visible row and reachable through reveal or the Item Bar.
3. Open Settings > General > Menu bar, then the Menu bar icon picker. Select Session dots,
   Usage meters, Usage meters with % left, Compact % left, Glyph only, Glyph
   with usage ring, Glyph with label, Orbit, and No icon, using the UI only.
   Also switch directly from Glyph only to Glyph with usage ring to test an
   equal-width style change.
4. After each selection, capture the whole bar and run the AX inspection
   command below with a distinct name. Capture the hiding diagnostic too.
   The log must name `the icon style changed` and a terminal verdict. No icon
   keeps its intentional chevron slot. No style may expose the chosen hidden
   run, overlap JR-Bar, lose the divider, or leave stale green counts after an
   incomplete scan. Compare native frames with the screenshots, not alone.
5. Restore the original style through Settings. Reveal the chosen hidden
   section, open its Item Bar, then close it and let the existing rehide delay
   finish. Capture the revealed and hidden states. Every chosen item must stay
   reachable. Do not use agent-action controls while checking reachability.

```sh
swift scripts/inspect-menu-bar.swift > "$jrbar_menu_receipts/items-after-style.json"
screencapture -x "$jrbar_menu_receipts/bar-after-style.png"
/usr/bin/log show --style compact --last 3m --info --predicate 'process == "JR-Bar" AND category == "menubar"' > "$jrbar_menu_receipts/check-after-style.log"
```

## Verify display changes and finish

1. Change the display resolution or arrangement through System Settings, or
   have Jonathan attach or detach a display. Do not write display or menu-bar preferences
   from a script.
2. Capture the settled bar, diagnostic, and a new AX reading. The log must
   name `the displays changed`, then a terminal verdict. Verify the divider
   fits the current screen and the same chosen run stays hidden and reachable.
3. Repeat after a normal quit and launch through the UI. Confirm one app and
   daemon pair, retained picks, and a fresh launch check. Restore the original
   display arrangement and icon style.
4. Save final app state and JR-Bar preferences with the commands above, using
   `after` filenames. Compare the menu-bar fields. Explain every change,
   including any layout change the owner chose. Capture and inspect every PNG.
5. Report each event's source commit, installed build, terminal verdict, item
   order, boundary frame, and visible result. If native overflow cannot be
   inspected or the old picks cannot be identified, leave their hiding status
   unverified. Do not call the fix live-verified until placement, style,
   display, reveal, and restart checks pass on the installed candidate.
