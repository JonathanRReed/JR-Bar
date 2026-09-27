# Quick start

JR-Bar becomes useful as soon as one provider sends it session events. No
hardware is required.

1. Open JR-Bar and choose **Settings > Agents**.
2. Find a provider already installed on this Mac, then click **Install** for
   its hook.
3. Start a new prompt in that provider. The session should appear in the
   panel after its first event.
4. Click the status item to open the panel. A real permission or input request
   stays pinned at the top with **Approve** and **Deny**. JR-Bar never answers
   one on its own.
5. Open the Usage Center to see the quota windows the provider actually
   reports. A missing window stays missing, and an old reading is marked
   stale.

If you use the Screen Bar, hover over the band to peek at its card. Click the
band to pin the card. Click the session mark on the left wing to open the
focused session.

Optional hardware uses the same light program, but it is a separate check.
A working Screen Bar does not prove a SidePulse strip or Creator Micro 2 has
been tested. See [Control Center](../CONTROL-CENTER.md) for the pad and the
[README](../../README.md#hardware-optional) for the lights.

Useful checks:

```sh
jrbar status
jrbar usage
jrbar hooks doctor
jrbar doctor
```

The command is optional. Install its link from **Settings > Shortcuts >
Command line**. If something remains offline, use [recovery](recovery.md).
