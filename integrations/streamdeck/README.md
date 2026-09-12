# Stream Deck (alpha scaffold)

A minimal Stream Deck plugin that polls JR-Bar's loopback status endpoint
and shows the redacted agent counts on a key: `N work`, `N wait`, `N fail`.
Pressing the key refreshes.

This is a scaffold, not a shipped integration. There are no icons, no
packaged release, and no Elgato store listing. Sideload it and keep
expectations accordingly.

## What it talks to

The daemon's `serve` endpoint — Settings › Devices & Screen Bar › Stream
Deck (the same switch as Settings › Remote › Serve status):

```
GET http://127.0.0.1:8737/status.json
Authorization: Bearer <token>
```

The token lives at `~/.local/state/jrbar/serve-token` (0600); the
Settings card's **Copy token** button fetches it over the local socket.
The reply is the redacted document `src/jrbar/serve.py` builds:
`agents.lifecycle_counts` (`active`, `waiting`, `completed`, `failed`),
quota summaries, timestamps. Loopback only, read only.

## Sideload

1. Turn on **Serve status** in Settings and copy the token.
2. Copy `com.jrbar.status.sdPlugin/` into
   `~/Library/Application Support/elgato/StreamDeck/Plugins/` and restart
   the Stream Deck software.
3. Drag the **JR-Bar › Agent counts** action onto a key, open its
   property inspector, and paste the token (the URL field may stay empty;
   it defaults to the loopback endpoint).

The action runs under whatever Node the Stream Deck software spawns and
needs Node 22+ semantics (global `WebSocket`, `fetch`). If your Stream
Deck runtime is older, wrap `app.js` with the official
`@elgato/streamdeck` SDK or shim `WebSocket` — the polling logic is
deliberately dependency-free.

## Files

- `com.jrbar.status.sdPlugin/manifest.json` — one keypad action,
  `com.jrbar.status.agents`.
- `com.jrbar.status.sdPlugin/app.js` — the plugin process: registers over
  the Stream Deck WebSocket, polls `status.json`, `setTitle`s the key.
- `com.jrbar.status.sdPlugin/pi.html` — the property inspector (token +
  optional URL override).
