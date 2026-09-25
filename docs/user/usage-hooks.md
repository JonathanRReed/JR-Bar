# Usage hooks

A usage hook runs a program of your own when something happens to your
quota: a window runs low or out, a window resets, or a provider stops
answering. Hooks are off until you turn them on. The idea comes from
CodexBar's external event hooks (MIT); JR-Bar has its own implementation.

## Events

| event | when |
| --- | --- |
| `quota_low` | a window crossed its provider's low threshold on the way down |
| `quota_reached` | a window ran out |
| `quota_reset` | a window reset (confirmed, see [reset confirmation](usage-sources.md#reset-confirmation)) |
| `usage_updated` | a window's remaining percent moved |
| `provider_unavailable` | a provider that was answering stopped |
| `provider_recovered` | it answers again |
| `refresh_failed` | a refresh came back with an error |

Each event is an edge, not a state, so your script does not need to limit
itself. `usage_updated`, `refresh_failed` and `provider_unavailable` also
run at most once every 10 minutes per rule, provider, account and window.

## Rules

A rule names:

- an event, or `*` for every event;
- optionally, a provider;
- optionally, a remaining percent: the rule fires only at or below it;
- an absolute path to a program, with its arguments.

```sh
jrbar usage-hooks add --event quota_low --provider claude --threshold 20 \
    /Users/me/bin/quota-alert.sh --loud
jrbar usage-hooks enable              # the master switch
jrbar usage-hooks list                # every rule, why any will not run, and each one's last result
jrbar usage-hooks test quota_low      # run the matching rules once with a made-up event
jrbar usage-hooks disable rule-1      # or enable, or remove, one rule
```

Settings › Usage › Hooks shows the same rules, each with its last result
and a Test button. Rules live in the settings under `usage_hooks`.

## What your program gets

It runs directly, never through a shell. Its environment is small:

- `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `LANG`, `LC_ALL`, `LC_CTYPE`,
  `TERM` and `TMPDIR`, copied from the daemon's environment;
- `JRBAR_EVENT`, `JRBAR_PROVIDER`, `JRBAR_INSTANCE`, `JRBAR_LANE`,
  `JRBAR_REMAINING_PERCENT`, `JRBAR_RESET_AT`, `JRBAR_STATE` and
  `JRBAR_TIMESTAMP`.

Nothing else in the daemon's environment reaches it, such as an API key.

On stdin it gets the event as one JSON document with sorted keys. Fields
that do not apply are left out:

```json
{"event": "quota_low", "instance": "default", "label": "5-hour", "lane": "five-hour",
 "provider": "claude", "remaining_percent": 18.0, "reset_at": 1790000000.0,
 "state": "ready", "threshold_percent": 20.0, "timestamp": 1789990000.0, "v": 1}
```

A `quota_reset` event also carries `event_id`. It is the same id the app's
celebration and the `quota_reset` wire event carry, so all three can be
matched to one reset. Account names and emails are never included.

A hook is killed when it runs past its timeout (15 s by default), and its
output is thrown away. [`examples/usage-hooks/`](../../examples/usage-hooks)
has a notification script and a JSONL logger to start from.

## Limits

Limits fail closed. A rule that breaks one never runs, and
`jrbar usage-hooks list` says why:

- more than 32 rules stops every rule;
- a rule with a relative path, more than 32 arguments, or a string over
  4 KiB never runs;
- an event whose JSON is over 4 KiB is not delivered.

## The first version's hook path

If you set `usage_event_hook_path` before, it became a rule with the id
`legacy`. That rule keeps the first version's arguments
(`EVENT PROVIDER LANE DETAIL`) and its five events. `usage_updated` and
`refresh_failed` reach it only if you change the rule's event to name one
of them.

The `legacy` rule still follows that key. Point `usage_event_hook_path` at
another program and the rule runs the new one; clear it and the rule is
removed. To change the program, change the key rather than the rule's
`executable`, which the key overwrites the next time the settings load.
