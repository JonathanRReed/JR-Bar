# Updating a SidePulse's firmware

JR-Bar can update the firmware of a SidePulse Pro or Dot for you. It is the
vendor's own procedure (copy one file to the device's drive, wait, check the
version), done with the checks you would want and an honest account of each
step. It only ever happens when you ask.

## What you do

1. Open **Settings > Devices & Lighting**. Each device card has a
   **Firmware** row showing its version and update status. **Check firmware**
   reads `STATUS.TXT` from the device. It makes no network request.
2. When an update is available, press **Review update...**. A sheet says exactly what will happen:
   what is downloaded (the host, the size and the version), that the LEDs go
   still for about a minute, that nothing else is written to the device, and,
   for a Pro, that the previous firmware stays in the other slot.
3. Press **Download and update**. The sheet shows each step as it happens and
   ends with the result. Leave the device connected and keep the Mac plugged
   in.

From a terminal the same thing is `jrbar firmware upgrade` (see
[the command line](cli.md#your-sidepulse-hardware)).

## What it does, in order

1. **Checking the device.** It reads the device's own status. It will not go
   on if the device is not the model it says (a Pro image is never written to a
   Dot's drive, nor the other way round), if its serial or firmware slot is
   unknown, if it looks busy, if it already runs the newest release, if another
   update is running, or if the Mac is on battery below 30%.
2. **Downloading and checking.** If the package is not already on this Mac, it
   is fetched once from `raw.githubusercontent.com` over https (no redirects,
   at most 1 MB). The app has the release's checksums built in and compares the
   download with them before opening it, then checks the file inside against
   its own checksum, size and model header. A package that fails is thrown
   away and nothing is written to the device. A verified package is kept in
   `~/.local/state/jrbar/firmware/` so a retry or a second device needs no
   download.
3. **Preparing the drive.** From here every write to the device's drive
   pauses: the lights, the keepalive and the other device of a linked pair. The
   drives are tiny: a Pro's holds 16 directory entries, and the hidden `._`
   files macOS makes beside a file use two each. JR-Bar counts them and removes
   only `._` files it has read and found to be macOS sidecars. It never removes
   `LEDS.LED`, `INIT.LED`, `STATUS.TXT`, `keepalive`, `setup.html`, `index.html`
   or `.fseventsd`. If there is still no room it tells you which files are in
   the way and stops.
4. **Copying.** One file, `FIRMWARE.BIN`, goes to the top of the drive and is
   flushed to the device.
5. **Restarting.** The device is left alone for at least 10 seconds, then
   JR-Bar waits up to two minutes for its drive to come back (under whatever
   name, found by its serial number).
6. **Confirming.** Only the version the device itself reports counts: it must
   read the new `release_version` (Pro) or `app_version` (Dot). Then the
   `._FIRMWARE.BIN` macOS made is tidied away, the lights resume, and the
   device repaints.

If any step fails, the device is on its old firmware: it applies an update only
from a complete, valid file. A drive that never comes back is reported as
**not confirmed**, never as a success; unplug the device, plug it in again and
check its firmware (`jrbar firmware version`).

## Good to know

- **Nothing is checked for in the background.** "An update is available" is
  worked out on this Mac by comparing the version the device reports with the
  releases built into JR-Bar. The only network request is the one download
  you start, and the app does nothing at launch.
- **A Pro keeps its old firmware.** It has two slots; after the update the old
  firmware is still in the other one, and the sheet says which. JR-Bar does
  not write a rollback: the vendor documents none.
- **Colour.** Pro firmware 1.1.0 balances colour inside the device. After an
  update that crosses it, JR-Bar suggests re-checking colour calibration, because
  a channel gain tuned for the old firmware now stacks on the device's own.
- **The Dot always shows a `FIRMWARE.BIN`.** Its drive serves a fixed file
  before and after an update, so the file being there proves nothing; the
  version in `STATUS.TXT` is what counts.
- **Offline use.** `jrbar firmware upgrade --from path/to/package.zip` uses a
  package you already have. It is checked exactly like a download, and it must
  be one of the releases built into JR-Bar.
- **Where the releases come from.** The SidePulse project publishes them at
  [inteliwear/sidepulse](https://github.com/inteliwear/sidepulse) under
  `firmware/`. JR-Bar's table of releases is refreshed when that project is
  reviewed ([docs/UPSTREAM-SYNC.md](../UPSTREAM-SYNC.md)); a release newer than
  your copy of JR-Bar is not offered.
