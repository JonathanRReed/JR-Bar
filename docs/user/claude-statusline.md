# Claude Code's status line

Claude Code runs a statusLine command after each reply and passes it a
JSON document. On Pro and Max accounts that document includes your 5-hour
and weekly limits: the same numbers the usage endpoint reports, taken from
Claude Code itself, with no extra request.

JR-Bar can read them. It is off by default.

## Turn it on

Either:

- Settings › Usage › Claude Code status line › **Read Claude Code's
  status line**; or
- `jrbar agent-monitor install claude-statusline`.

Both point Claude Code's `statusLine` in `~/.claude/settings.json` at the
bundled `jrbar-hook --statusline`, and both turn the source on.

JR-Bar never replaces a status line you already have. If one exists, the
command refuses and Settings asks first. Choosing **Keep Mine and Add
JR-Bar's Line** (or `--wrap` on the command line) runs your old command
after JR-Bar's line. Turning it off
(`jrbar agent-monitor uninstall claude-statusline`) puts back exactly what
was there before.

## What it shows in Claude Code

One line, in numbers and words:

```text
JR-Bar · 2 working · 1 needs you · 5h 58% left
```

To keep the reading without showing the line, turn off **Show JR-Bar's
line**.

## What JR-Bar keeps

Only the session id, the model id and the two rate-limit windows. The
prompt, the transcript path, the working folder and every other field are
dropped as soon as the document arrives.

A window whose reset time has passed is dropped. A document with no rate
limits (an API-key account, or an older Claude Code) counts as no
reading at all.

The status line redraws while Claude is idle, so it never counts as agent
activity: it cannot keep a session looking busy.

## When it is used

The usage endpoint comes first. The status line reading stands in only
when that endpoint is rate limited, signed out or unavailable, and only
while the reading is under 15 minutes old. When it stands in, the Usage
Center and `jrbar usage` say "via Claude Code".
