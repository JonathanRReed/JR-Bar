#!/usr/bin/env node
// JR-Bar Stream Deck action — ALPHA SCAFFOLD, sideload via the Stream Deck
// software. Polls the daemon's loopback status endpoint
// (Settings › Devices & Screen Bar › Stream Deck, or Settings › Remote ›
// Serve) and shows the redacted agent counts on the key.
//
// Runs under whatever Node the Stream Deck software spawns; needs global
// WebSocket and fetch (Node 22+). No dependencies on purpose: the token
// never leaves loopback and neither does this file.

"use strict";

const args = process.argv.slice(2);
const arg = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};

const port = arg("-port");
const pluginUUID = arg("-pluginUUID");
const registerEvent = arg("-registerEvent") || "registerPlugin";

const DEFAULT_URL = "http://127.0.0.1:8737/status.json";
const POLL_MS = 2000;

if (typeof WebSocket === "undefined" || typeof fetch === "undefined") {
  console.error("jrbar-streamdeck: this Node has no global WebSocket/fetch; run under Node 22+");
  process.exit(1);
}

// Per-key state: context -> {settings, timer}.
const contexts = new Map();
let socket;

function connect() {
  socket = new WebSocket(`ws://127.0.0.1:${port}`);
  socket.onopen = () => {
    socket.send(JSON.stringify({ event: registerEvent, uuid: pluginUUID }));
  };
  socket.onmessage = (message) => {
    let event;
    try { event = JSON.parse(message.data); } catch { return; }
    handle(event);
  };
  socket.onclose = () => {
    for (const entry of contexts.values()) clearInterval(entry.timer);
    contexts.clear();
    setTimeout(connect, 3000);
  };
  socket.onerror = () => socket.close();
}

function handle(event) {
  const context = event.context;
  switch (event.event) {
    case "willAppear":
      contexts.set(context, { settings: event.payload?.settings ?? {}, timer: null });
      startPolling(context);
      break;
    case "didReceiveSettings":
      if (contexts.has(context)) contexts.get(context).settings = event.payload?.settings ?? {};
      break;
    case "willDisappear": {
      const entry = contexts.get(context);
      if (entry) clearInterval(entry.timer);
      contexts.delete(context);
      break;
    }
    case "keyDown":
      poll(context); // press = refresh now
      break;
  }
}

function startPolling(context) {
  const entry = contexts.get(context);
  if (!entry) return;
  clearInterval(entry.timer);
  entry.timer = setInterval(() => poll(context), POLL_MS);
  poll(context);
}

async function poll(context) {
  const entry = contexts.get(context);
  if (!entry || socket?.readyState !== WebSocket.OPEN) return;
  const url = (entry.settings.url || DEFAULT_URL).trim() || DEFAULT_URL;
  const token = (entry.settings.token || "").trim();
  let title;
  try {
    const reply = await fetch(url, {
      headers: token ? { Authorization: `Bearer ${token}` } : {},
      signal: AbortSignal.timeout(1500),
    });
    if (reply.status === 401) {
      title = "auth\nneeded";
    } else if (!reply.ok) {
      title = `http\n${reply.status}`;
    } else {
      const doc = await reply.json();
      const counts = doc?.agents?.lifecycle_counts ?? {};
      const working = counts.active ?? 0;
      const waiting = counts.waiting ?? 0;
      const failed = counts.failed ?? 0;
      title = `${working} work\n${waiting} wait${failed ? `\n${failed} fail` : ""}`;
    }
  } catch {
    title = "jrbar\noffline";
  }
  socket.send(JSON.stringify({
    event: "setTitle",
    context,
    payload: { title, target: 0 },
  }));
}

connect();
