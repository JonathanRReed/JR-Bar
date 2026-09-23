# SidePulse Pro and SidePulse Dot - How it works

SidePulse Pro and SidePulse Dot expose an LED controller as a virtual filesystem, inspired by Linux sysfs. LED animations are controlled by writing commands to the LEDS.LED file.
No drivers are needed.
SidePulse Pro fits into the SD card slot on MacBook Pro 2021+ models and has 8 RGB LEDs. SidePulse Dot is a tiny 2-LED USB-C device for Mac, iPhone, Linux, and Windows.


On macOS they mount under `/Volumes/SidePulsePro` and `/Volumes/SidePulseDot`.

The simplest way to change the color is

    $ echo "#FF00FF" > /Volumes/SidePulsePro/LEDS.LED

Or to slowly pulse it.

     $ echo "off\n#FF00FF 1s pulse\nrepeat" > /Volumes/SidePulsePro/LEDS.LED


There is a quirk with the MacBook SD card reader: it can power off SidePulse Pro after 3 minutes of inactivity.
A simple way to prevent it is to 'touch' it once a minute like

    $ touch /Volumes/SidePulsePro/keepalive

or

    $ while touch /Volumes/SidePulsePro/keepalive; do sleep 60; done

To recap, write to LEDS.LED what you want displayed.
That's all you have to know.

## Initial state.

The content in INIT.LED is played on power up. It can be anything supported by LEDS.LED.
Fresh firmware seeds INIT.LED with the one-second startup fill sequence.
Writing INIT.LED also applies the new startup program immediately for visual confirmation.

# LEDS.LED DSL

Write LED animation programs to `LEDS.LED`. Each non-empty, non-comment line is
one animation step. The embedded controller accepts at most 512 bytes and at
most 20 physical lines.

The controller keeps the current visible LED state across parses. A successful
parse starts the new program from line 1 using the current state as the
transition start colors. A parse error stops the current program and blinks all
LEDs red six times with 150 ms on/off phases.

The rules below are the firmware parser's own, probed against the packaged
`sdled.wasm` (the verdicts live in `app/Tests/JRBarLEDSTests/Fixtures`; the
Swift port that mirrors them is `app/Sources/JRBarLEDS/LEDSParser.swift`). The
size limits are checked first: more than 512 UTF-8 bytes is `too-long` before
anything else is read, and more than 20 lines is `too-many-lines`. `\r\n`,
`\n` and `\r` all end a line, and one trailing line break does not start a new
line. Keywords, easing names and the `ms`/`s` suffixes are case-insensitive:
`OFF`, `Repeat`, `COSINE` and `330MS` all parse.

JR-Bar's own gate in front of every device write is stricter in two places,
so a program it shows never reads differently on the device: it refuses a
tab anywhere in a line, and a time with more than three fraction digits.

## Comments

Blank lines are ignored. A comment is recognised only at the start of a line
(after any spaces or tabs), in three spellings:

* `//` followed by anything;
* `;` followed by anything -- elsewhere on a line `;` separates segments;
* `#` alone, or `#` followed by a space or a tab. `#` followed by anything
  else is a colour, so `#comment` fails as `bad-color`.

```text
# all LEDs white
#ffffff

; all LEDs off
off
```

## Colors

Set all LEDs to one color:

```text
#ffffff
```

Turn all LEDs off:

```text
off
```

Assign colors by position. LEDs past the list turn off. Extra colors past the
compiled LED count are checked for valid syntax, then ignored:

```text
#ff0000 #00ff00 #0000ff
```

Assign specific LEDs. Unmentioned LEDs hold their current state. Indexes past
the compiled LED count are checked for valid syntax, then ignored:

```text
0:#ffffff 2:#ff00ee 7:#0040ff
```

Colours are always six hex digits: `#fff` is `bad-color`. An indexed LED takes
a colour, never a keyword: `0:off` (and `0:` or `0:#fff`) is `bad-index` --
write `0:#000000` to turn one LED off.

Multiple segments may appear on one line, separated by semicolons; an empty
segment (`;;`) is ignored. If an LED is assigned more than once on a line, the
last assignment wins:

```text
0:#ff0000 1s; 0:#0000ff 1s
```

A colour list and indexed assignments cannot share one segment: in
`#ff0000 0:#00ff00` the `0:#00ff00` is read where the timing belongs and fails
as `bad-time`. Give each its own segment: `#ff0000; 0:#00ff00`.

## Brightness

Brightness scales the RGB values. It does not change the stored animation colors. Each successful parse starts with brightness 255 unless
the program includes `brightness N`, where `N` is a whole number from 0 to 255
(anything else is `bad-brightness`) and nothing may follow it on the line.

```text
brightness 128
#808080
```

## Timing

A color assignment may be followed by:

```text
duration
easing
duration easing
duration easing delay
duration delay
easing delay
```

Durations and delays accept integer milliseconds, integer seconds, or decimal
seconds, up to 65535 ms. A decimal needs a digit before the point (`.5s` is
`bad-time`, write `0.5s`) and keeps only its first three fraction digits:
`0.3333s` is 333 ms.

```text
#ff00ff 330ms
#ff00ff ease-in
#ff00ff 0.33s
#ff00ff 0.33s ease-in
#ff00ff 0.33s ease-in 1s
#ff00ff pulse 1s
```

An easing name without a duration uses the default 330 ms duration. Each line
finishes after the longest delay plus duration on that line. A line with no
duration, easing, or delay lasts one 60 Hz frame.

## Easing

Supported easing names:

```text
linear
ease
ease-in
ease-out
ease-in-out
cosine
pulse
none
```

`cosine` is a smooth half-cosine transition from the line's start color to the
target color. `pulse` is a full-cycle envelope: it moves from the line's start
color to the target color and back to the start color over one duration. The
target color is the peak, not the final hold.

```text
// fade to purple
#ff00ff 0.33s cosine

// pulse to purple and return to the current color
#ff00ff 1.4s pulse

// same pulse using the default 330 ms duration
#ff00ff pulse
```

`none` jumps to the target after any delay and holds until the line finishes:

```text
3:#ffffff 80ms none
```

## Roll

Roll the current visible LED state by one full wraparound loop:

```text
roll 2s
roll 2s linear
roll 2s ease
roll-left 800ms ease-in-out
roll-right 1.5s cosine
```

`roll` is an alias for `roll-right`. Missing easing defaults to `linear`.
Duration is the time for one complete loop, so `roll 2s` returns to the
starting arrangement after 2 seconds. A roll owns its line: a `;` anywhere on
it fails as `bad-time`. Roll always uses the current visible LED
state as its source. To roll a chosen palette, set it first:

```text
#ff0044 #ff8800 #ffff00 #00ff66 #00ccff #004cff #8800ff #ff00cc
roll 2s linear
repeat
```

## Delays And Staggering

Different LEDs can use independent timing on the same line:

```text
0:#ff00ff 0.33s ease-in 0s; 1:#00ff00 0.33s linear 250ms
```

Stagger all 8 LEDs:

```text
0:#ff0000 150ms ease 0ms; 1:#ff8000 150ms ease 50ms; 2:#ffff00 150ms ease 100ms; 3:#00ff00 150ms ease 150ms
4:#00ccff 150ms ease 0ms; 5:#004cff 150ms ease 50ms; 6:#8800ff 150ms ease 100ms; 7:#ff00cc 150ms ease 150ms
```

## Repeat

`repeat` may appear once per program, and only after a line that lights
something -- a paint that reaches a real LED, or a roll. A `repeat` with
nothing lit before it (only comments, `brightness`, or indexes past the LED
count) is `bad-repeat`, and the firmware reports it on the line after the
`repeat`. A count is a whole number from 1 to 65535.

Loop forever from the first animation line:

```text
0:#ffffff 80ms none
1:#ffffff 80ms none
2:#ffffff 80ms none
repeat
```

Run the animation before the repeat marker 10 total times, then hold the final
state:

```text
#ff0000 200ms none
#00ff00 200ms none
repeat 10
```

Finite repeat can continue with more animation lines:

```text
off
#ff0000 200ms none
#00ff00 200ms none
repeat 2
off
```

## Examples

Soft breathing pulse:

```text
#404040 1.4s pulse
off 400ms none
repeat
```

One-line chase step. Only LED 3 changes; all others hold:

```text
3:#ffffff 80ms none
```

Indexed sparkle:

```text
0:#ffffff 90ms none
2:#ff00ee 90ms none
5:#00ccff 90ms none
off 120ms ease-out
repeat
```

Smooth seeded roll:

```text
#ff0044 #ff8800 #ffff00 #00ff66 #00ccff #004cff #8800ff #ff00cc
roll 2s linear
repeat
```

Compile-time LED count matters, but shared scripts are portable. On an 8 LED
build, indexes `0` through `7` affect LEDs. On a 2 LED build, only indexes `0`
and `1` affect LEDs. Higher indexes and extra color-list entries are parsed so
bad syntax still fails, but valid out-of-range LED targets are ignored. A line
that only targets ignored LEDs is a no-op.
