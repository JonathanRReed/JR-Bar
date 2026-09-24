# CLIProxyAPI as a usage hub

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) signs in to
Claude and Codex accounts and proxies requests for them. If you run it,
JR-Bar can read the usage of the accounts it holds, so an account that
only the proxy signs in to still gets a card in the Usage Center. The
hub is off by default.

## Turn it on

1. Store the proxy's management key in the Keychain:

   ```sh
   printf '%s' "$MANAGEMENT_KEY" | jrbar providers credential set cliproxy management --stdin
   ```

2. Turn the hub on. The URL defaults to `http://127.0.0.1:8317`:

   ```sh
   jrbar set cliproxy_hub.enabled true
   jrbar set cliproxy_hub.url http://127.0.0.1:8317   # only if yours differs
   ```

Without the key, the hub says it needs one and makes no requests.

## What it does

- It connects only to a loopback address. Any other URL is refused before
  a connection is made.
- It asks at most once every 5 minutes (`cliproxy_hub.min_interval_seconds`,
  300 to 3600).
- It lists the proxy's accounts and reads each one's usage through the
  proxy's `api-call` route; the proxy fills in the account's own token.
  From CLIProxyAPI 7.3 on, it also uses the read-only quota routes.
- It never calls the proxy's reset or consume routes. Those change your
  quota, and JR-Bar refuses them outright.
- An account this Mac already reads directly (the same Codex account, the
  same Claude email) is left out, so nothing is counted twice.

Hub accounts show in the Usage Center with a CLIProxyAPI badge. Only
their 5-hour and weekly windows can drive the lights; anything else is
shown as detail.

The hub reads quota, not requests. The Data Hoarder's request history
comes from the proxy's own log files, which it writes only with
`request-log: true` in its config.
