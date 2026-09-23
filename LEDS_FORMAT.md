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

In JR-Bar, Effect Studio › Program is an editor for this language. It checks
every keystroke with the same rules as the firmware, points at the line and
column the firmware would reject, shows the byte and line budget, previews the
program on the strip, the Dot and the Screen Bar, and can burn it into
INIT.LED.

## Initial state.

The content in INIT.LED is played on power up. It can be anything supported by LEDS.LED.
Fresh firmware seeds INIT.LED with the one-second startup fill sequence.
Writing INIT.LED also applies the new startup program immediately for visual confirmation.

# LEDS.LED DSL

Write LED animation programs to `LEDS.LED`. Each non-empty, non-comment line is
one animation step. The embedded controller accepts at most 512 bytes and at
most 20 physical lines.

The 512 bytes are UTF-8 bytes, and they are checked first: a longer program is
refused as `too-long` before any line is read. Lines break on `\n`, `\r\n` or
`\r`. One trailing line break does not start a new line, but blank lines and
comment lines count toward the 20.

The controller keeps the current visible LED state across parses. A successful
parse starts the new program from line 1 using the current state as the
transition start colors. A parse error stops the current program and blinks all
LEDs red six times with 150 ms on/off phases.

Keywords, easing names and time suffixes are case-insensitive: `OFF`, `Repeat`,
`Ease-In` and `500MS` all work.

## Comments

Blank lines are ignored. A line is a comment when its first non-blank
characters are `//`, `;`, or a `#` that stands alone or is followed by a space
or tab.

```leds
# all LEDs white
#ffffff

; all LEDs off
off
```

`#` followed directly by anything else is read as a color, so `#c` is a
`bad-color` error, not a comment. A comment only ever starts a line: later on
a line, `;` separates segments and `#` begins a color.

```leds-error bad-color
#note to self
```

## Colors

A color is `#` and exactly six hex digits. The three-digit shorthand is not
supported.

Set all LEDs to one color:

```leds
#ffffff
```

Turn all LEDs off:

```leds
off
```

Assign colors by position. LEDs past the list turn off. Extra colors past the
compiled LED count are checked for valid syntax, then ignored:

```leds
#ff0000 #00ff00 #0000ff
```

Assign specific LEDs. Unmentioned LEDs hold their current state. Indexes past
the compiled LED count are checked for valid syntax, then ignored:

```leds
0:#ffffff 2:#ff00ee 7:#0040ff
```

An index takes a six-digit color. `off` is not a color here: turn one LED off
with `#000000`.

```leds
3:#000000 200ms ease-out
```

```leds-error bad-index
3:off
```

Multiple segments may appear on one line, separated by semicolons. If an LED is
assigned more than once on a line, the last assignment wins. Empty segments are
ignored:

```leds
0:#ff0000 1s; 0:#0000ff 1s
```

One segment is either a color list or index assignments, never both. Put them
in separate segments:

```leds-error bad-time
#ff0000 #00ff00 3:#0000ff
```

```leds
#ff0000 #00ff00; 3:#0000ff
```

## Brightness

Brightness scales the RGB values. It does not change the stored animation colors. Each successful parse starts with brightness 255 unless
the program includes `brightness N`, a whole number from 0 to 255. Brightness
is global, not a step: it applies to the whole program wherever the line
appears, and if there are several, the last one wins.

```leds
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
seconds, up to 65535 ms. A decimal needs a digit before the point (`0.5s`, not
`.5s`) and keeps three fraction digits (`0.3333s` is 333 ms). A bare number
with no `ms` or `s` is an error.

```leds
#ff00ff 330ms
#ff00ff ease-in
#ff00ff 0.33s
#ff00ff 0.33s ease-in
#ff00ff 0.33s ease-in 1s
#ff00ff pulse 1s
```

```leds-error bad-time
#ff00ff 500
```

An easing name without a duration uses the default 330 ms duration. A duration
without an easing uses `ease`. Each line finishes after the longest delay plus
duration on that line. A line with no duration, easing, or delay lasts one
60 Hz frame, which the firmware rounds up to 17 ms.

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

```leds
// fade to purple
#ff00ff 0.33s cosine

// pulse to purple and return to the current color
#ff00ff 1.4s pulse

// same pulse using the default 330 ms duration
#ff00ff pulse
```

`none` jumps to the target after any delay and holds until the line finishes:

```leds
3:#ffffff 80ms none
```

## Roll

Roll the current visible LED state by one full wraparound loop:

```leds
#ff0044 #ff8800 #ffff00 #00ff66 #00ccff #004cff #8800ff #ff00cc
roll 2s
roll 2s linear
roll 2s ease
roll-left 800ms ease-in-out
roll-right 1.5s cosine
```

`roll` is an alias for `roll-right`. Missing easing defaults to `linear`.
Duration is the time for one complete loop, so `roll 2s` returns to the
starting arrangement after 2 seconds. A roll needs a duration, and it owns its
line: no semicolon segments beside it.

```leds-error bad-time
#ff0044 #ff8800
roll 2s; #ffffff
```

Roll always uses the current visible LED state as its source. To roll a chosen
palette, set it first:

```leds
#ff0044 #ff8800 #ffff00 #00ff66 #00ccff #004cff #8800ff #ff00cc
roll 2s linear
repeat
```

## Delays And Staggering

Different LEDs can use independent timing on the same line:

```leds
0:#ff00ff 0.33s ease-in 0s; 1:#00ff00 0.33s linear 250ms
```

Stagger all 8 LEDs:

```leds
0:#ff0000 150ms ease 0ms; 1:#ff8000 150ms ease 50ms; 2:#ffff00 150ms ease 100ms; 3:#00ff00 150ms ease 150ms
4:#00ccff 150ms ease 0ms; 5:#004cff 150ms ease 50ms; 6:#8800ff 150ms ease 100ms; 7:#ff00cc 150ms ease 150ms
```

## Repeat

Loop forever from the first animation line:

```leds
0:#ffffff 80ms none
1:#ffffff 80ms none
2:#ffffff 80ms none
repeat
```

Run the animation before the repeat marker 10 total times, then hold the final
state:

```leds
#ff0000 200ms none
#00ff00 200ms none
repeat 10
```

Finite repeat can continue with more animation lines:

```leds
off
#ff0000 200ms none
#00ff00 200ms none
repeat 2
off
```

A count runs from 1 to 65535. `repeat` may appear only once, and it needs a
line before it that lights a real LED (or a roll). A repeat with nothing to
repeat is reported on the line after it, or on the repeat itself when it is
the last line:

```leds-error bad-repeat
brightness 64
repeat
```

## Errors

A rejected program names its error, the line and the column. Effect Studio
shows the same name and position the firmware uses.

```text
too-long         more than 512 bytes
too-many-lines   more than 20 lines
syntax           a line that is not a color, off, an index, brightness, roll or repeat
bad-color        a color that is not # and six hex digits
bad-index        an index assignment without a six-digit color
bad-time         a timing, easing or segment the grammar does not allow
bad-brightness   brightness without a whole number from 0 to 255
bad-repeat       a repeat that is premature, repeated, or out of range
trailing-input   something extra after a complete instruction
```

```leds-error syntax
blink #ff0000
```

```leds-error bad-brightness
brightness 300
```

```leds-error trailing-input
#ff0000 1s ease 200ms 50ms
```

## Examples

Soft breathing pulse:

```leds
#404040 1.4s pulse
off 400ms none
repeat
```

One-line chase step. Only LED 3 changes; all others hold:

```leds
3:#ffffff 80ms none
```

Indexed sparkle:

```leds
0:#ffffff 90ms none
2:#ff00ee 90ms none
5:#00ccff 90ms none
off 120ms ease-out
repeat
```

Smooth seeded roll:

```leds
#ff0044 #ff8800 #ffff00 #00ff66 #00ccff #004cff #8800ff #ff00cc
roll 2s linear
repeat
```

Compile-time LED count matters, but shared scripts are portable. On an 8 LED
build, indexes `0` through `7` affect LEDs. On a 2 LED build, only indexes `0`
and `1` affect LEDs. Higher indexes and extra color-list entries are parsed so
bad syntax still fails, but valid out-of-range LED targets are ignored. A line
that only targets ignored LEDs is a no-op and takes no time.

JR-Bar plays every program through a presentation compiler before it reaches a
strip, a Dot or the Screen Bar: nothing flashes faster than 2 Hz (1 Hz for
saturated red). It only ever lengthens timings, and Effect Studio › Program
says when it has.
