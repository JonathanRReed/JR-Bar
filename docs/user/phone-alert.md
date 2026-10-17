# A line on your phone

JR-Bar can send one short line to your phone when an agent needs you or has
finished, through [ntfy](https://ntfy.sh). It is off until you set it up.

It only tells you. Nothing on your phone can approve, deny or reply to an
agent; you answer at the Mac, the same as always.

## Set it up

1. Install the ntfy app on your phone and subscribe to a topic of your own.
   Pick a long name nobody would guess, such as `mac-agents-7k2q9x`: anyone who
   knows a topic on ntfy.sh can read it.
2. In Settings › Alerts & Sounds › Phone alert, type that topic into **ntfy topic**. If
   you run your own ntfy server, type its https address instead
   (`https://ntfy.example.com/mac-agents`).
3. Press **Send test message**. Your phone should show a line that starts
   with "JR-Bar test". The result appears in Settings in plain words.
4. Turn on **Send phone alerts**.

Until you have entered a topic and turned the switch on, JR-Bar sends nothing.
A topic on its own sends nothing, and the switch stays dim until there is one.
The test message is the only line that goes out before you turn it on, and
only because you pressed the button.

## What you get

One line, in a fixed shape:

- `Claude needs you`
- `Codex finished`

The name is the agent's own name from JR-Bar's list, or "An agent" for one it
does not know. The line never carries your prompt, a file path, a project name,
a token or anything else the agent said.

## Only when you are away

**Only when I'm away** is on by default. A line goes out only while your screen
is locked, or the Mac has been idle for five minutes. If you are at the Mac,
you do not need a phone buzz. If JR-Bar cannot tell whether you are away, it
sends nothing.

Turn it off to get a line whenever an agent needs you or finishes, even with
you at the keyboard.

## Limits

- The same agent saying the same thing is sent once per 20 seconds at most, and
  never more than 30 lines an hour.
- It follows your quiet settings: if a Focus or Do Not Disturb choice holds back
  webhooks, it holds this back too.
- Nothing is retried. A line that cannot get through is dropped.

The details of what leaves the Mac are in [SECURITY.md](../../SECURITY.md).
