# Screen Bar profiling

JR-Bar separates runtime measurements from Instruments measurements. A runtime
capture proves what the app observed. An Instruments profile adds wakeups,
energy impact, memory and CPU evidence from a raw trace. Neither is a release
claim by itself.

The Python renderer that exported runtime captures is gone. The daemon no
longer draws the Screen Bar, and the Swift band does not export a runtime
profile. Use Instruments against the installed `JR-Bar` process for current
measurements. A native exporter is still needed to complete the matrix below;
the [roadmap](ROADMAP.md) tracks it with the controlled performance
measurements.

## Required matrix

Capture each scenario for at least five minutes:

1. `static`
2. `working`
3. `asking`
4. `multi-agent`
5. `dnd`
6. `low-power`
7. `hidden`

A native capture has to show the state it was taken in. The DND run counts
only when JR-Bar can observe an active macOS Focus, and an unreadable Focus
state stays `unknown` instead of becoming a successful DND observation. The
low-power run counts only while Low Power Mode is active. The hidden run counts
only when the Screen Bar is not visible and presents no frames.

## Measure with Instruments

Record the installed `JR-Bar` process in Apple Instruments for the full
scenario. Keep the raw `.trace` file and note which state was held. From the
trace, read:

- the measured duration, which must cover the whole scenario
- wakeups per second
- energy impact
- peak resident memory
- average CPU percent and CPU time

An Instruments trace cannot say what state the Screen Bar was in. That is the
gap the native exporter closes. Until it exists, a trace alone does not
complete a row of the matrix.

For a CPU diagnostic, the Activity Monitor export and its analyzer are in
[Local verification](LOCAL-VERIFICATION.md). The release gate takes its
performance numbers from the evidence file described in the
[production release gate](PRODUCTION-RELEASE.md).

## Current external gate

On 2026-09-05, Xcode 27 Beta was located at
`/Users/jonathanreed/Downloads/Xcode-beta.app`. Its Instruments tools work when
commands set `DEVELOPER_DIR` to that app's `Contents/Developer` directory.
The system-wide selection still points to Command Line Tools.

A 301.344-second Time Profiler diagnostic capture completed for the signed
local candidate, PID 53091. It covered mixed live activity and Settings use,
without a paired scenario runtime export. It therefore does not complete any
row of the matrix above. The seven controlled captures, physical-device
energy evidence, and final budget checks remain required.
