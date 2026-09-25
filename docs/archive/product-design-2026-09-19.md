# JR-Bar product design

Status: approved by Jonathan after all three interview rounds and final review.

## Purpose

JR-Bar serves people running several AI agents. Jonathan's daily workflow is the
first proving ground. The most serious failures are missed requests for attention
and lost session history. Mac utilities and toys remain in scope and must feel
cohesive, reliable, and responsive.

## Notch and Screen Bar

Use Alcove as the reference for restrained shape and responsive motion. Keep one
continuous black body with one integrated Screen Bar light. Expansion, dismissal,
hover, and interrupted gestures must maintain a coherent outline. Respect Reduce
Motion, keep controls accessible, and keep expanded content within the display.

Requests needing attention take priority, then failures, then the user's chosen
everyday view. Ordinary activity stays compact. Users can pin media or agent
status. Detailed controls and full history belong in ordinary windows.

## AI tracking and actions

Keep direct agent integrations. Add CLIProxyAPI as an optional source and use its
request accounting as a reference for improving tracking. Existing workflows
must not require rerouting traffic through a proxy.

Combine evidence without equating an API request with a complete agent task.
Show unavailable or uncertain information honestly. Preserve source identity so
users can understand where a status, usage value, or archived record came from.

Support explicit actions such as opening sessions and answering approval requests
where the integration supports them. Do not automatically approve, retry, or
terminate work. Unsupported actions must be clear in the interface.

## Data Hoarder

Provide a local archive for searching past AI work and reconstructing failures.
Capture selected AI sessions, traces, conversations, and related artifacts. Full
prompt and response capture is an explicit setting. Clipboard history, browser
activity, screenshots, and unrelated files are outside this agreed scope.

Store durable copies of captured traces and conversations. Copy generated
artifacts when explicitly saved, and link to working repositories. The archive
must not depend on a proxy's temporary queue or the continued existence of the
original trace file.

Before importing existing history, show discovered sources with date ranges and
sizes. Import only selected sources, preserve originals, and prevent duplicates.
Future capture runs only for enabled sources.

Keep saved records until deliberately deleted. Show storage usage and provide
export and cleanup controls. Do not silently discard history to meet a size cap.
Report capture failures and gaps rather than presenting an incomplete archive
as complete.

## Utilities and toys

Give each utility and toy an independent toggle with shared settings conventions.
Disabled modules must stop their background work. Preserve existing settings and
progress. Complete the Menu Bar hiding/recovery, Dock interaction, Notch, Fold,
Aquarium, Buddy, and Confetti quality work already in scope.

Judge paid alternatives through specific workflows, visual behavior, reliability,
and measured performance. A larger feature list does not establish superiority.

## Evidence required

- Verify installed Notch interactions, combined Screen Bar appearance, overflow,
  accessibility, and motion, including interrupted transitions.
- Verify Menu Bar choices and recovery, Dock previews, and settings across
  relaunches. Protect existing user data during updates.
- Verify tracking against source fixtures and supported live integrations,
  including missing metadata, reconnects, and overlapping sessions.
- Verify archive persistence, duplicate prevention, original-file removal,
  partial ingestion, export, and explicit cleanup.
- Inspect every utility and toy in the installed app and measure background work
  for enabled, hidden, and disabled states.

Existing receipts remain in `docs/finish-2026-09-19.md`. This design does not claim
those acceptance checks are complete. Implementation proceeds in verified slices
without dropping the remaining scope. No commits, pushes, public releases,
paid services, or external content uploads are authorized by this design.
