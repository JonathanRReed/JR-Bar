#!/bin/bash
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title JR-Bar Status
# @raycast.mode fullOutput
#
# Optional parameters:
# @raycast.packageName JR-Bar
# @raycast.description Your coding agents and every provider's quota windows, from JR-Bar.
#
# A Raycast script command. It needs the `jrbar` command line: install it from
# JR-Bar's Settings › Shortcuts › Command line (it lands in ~/.local/bin).
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v jrbar >/dev/null 2>&1; then
    echo "jrbar is not installed: JR-Bar › Settings › Shortcuts › Command line › Install"
    exit 1
fi
jrbar status
echo
jrbar usage
