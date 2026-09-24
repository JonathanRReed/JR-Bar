#!/bin/bash
set -euo pipefail

# Removes JR-Bar from one user's Mac: the hooks it wrote, its helpers, the
# `jrbar` command-line link, the app, and (with --purge-state) its data.
#
# The app installs to ~/Applications (make clean-install, the default pkg
# choice) or /Applications (sudo installer). Both are probed, in that order.
# The `jrbar` link lives at ~/.local/bin/jrbar (Settings > Shortcuts >
# Command line) or, from older packages, /usr/local/bin/jrbar. A link is
# removed only when it points into a JR-Bar bundle, the same rule the app's
# own Remove button uses; anything else at that path is left alone.
#
# --dry-run prints every step instead of taking it and needs no sudo. The
# JRBAR_* variables below exist for that dry run and for tests: JRBAR_HOME
# skips the directory lookup, JRBAR_APP_PATH and JRBAR_CLI_LINK pin one path.

PACKAGE_ID="com.jonathanreed.jrbar"
LEGACY_PACKAGE_ID="io.sidepulse.app"
# The retired Python menu bar's LaunchAgent, and its pre-rename labels.
RETIRED_AGENT_LABELS="com.jonathanreed.jrbar.app io.sidepulse.agentstatus com.sidepulse.agentstatus"
RECEIPT_DIR="${JRBAR_RECEIPT_DIR:-${SIDEPULSE_RECEIPT_DIR:-/var/db/jrbar}}"
LEGACY_RECEIPT_DIR="/var/db/sidepulse"
PURGE_STATE=0
REMOVE_APP=1
DRY_RUN=0
TARGET_USER="${JRBAR_USER:-${SIDEPULSE_USER:-}}"

usage() {
    cat <<'EOF'
Usage: sudo ./scripts/uninstall-macos.sh [options]

  --user NAME    Remove user-owned JR-Bar integrations for NAME.
  --keep-app     Keep JR-Bar.app (in ~/Applications or /Applications).
  --purge-state  Also remove JR-Bar settings, logs, and local history.
  --dry-run      Print each step instead of taking it (no sudo needed).
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --user)
            shift
            [ "$#" -gt 0 ] || { usage >&2; exit 2; }
            TARGET_USER="$1"
            ;;
        --keep-app) REMOVE_APP=0 ;;
        --purge-state) PURGE_STATE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ "$DRY_RUN" -eq 0 ] && [ "$(/usr/bin/id -u)" -ne 0 ]; then
    echo "Run the macOS uninstaller with sudo (or add --dry-run to see the steps)." >&2
    exit 2
fi

if [ -z "$TARGET_USER" ]; then
    TARGET_USER="$(/usr/bin/stat -f '%Su' /dev/console)"
fi
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ] || [ "$TARGET_USER" = "loginwindow" ]; then
    echo "Specify the JR-Bar user with --user NAME." >&2
    exit 2
fi

if [ -n "${JRBAR_HOME:-}" ]; then
    TARGET_HOME="$JRBAR_HOME"
else
    TARGET_HOME="$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
fi
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "Could not resolve a safe home directory for $TARGET_USER." >&2
    exit 2
fi
TARGET_UID="$(/usr/bin/id -u "$TARGET_USER" 2>/dev/null || echo 0)"

# Take a step, or with --dry-run say it.
act() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# Which JR-Bar.app: an explicit path, else the user's, else the system's.
if [ -n "${JRBAR_APP_PATH:-${SIDEPULSE_APP_PATH:-}}" ]; then
    APP_PATH="${JRBAR_APP_PATH:-$SIDEPULSE_APP_PATH}"
elif [ -d "$TARGET_HOME/Applications/JR-Bar.app" ]; then
    APP_PATH="$TARGET_HOME/Applications/JR-Bar.app"
else
    APP_PATH="/Applications/JR-Bar.app"
fi
echo "JR-Bar.app: $APP_PATH"
# The Swift app takes no arguments; the command line is the bundled daemon.
APP_BINARY="$APP_PATH/Contents/MacOS/JR-Bar"
CORE_BINARY="$APP_PATH/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core"

if [ ! -x "$CORE_BINARY" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "note: the bundled daemon is missing ($CORE_BINARY); a real run would stop here."
    else
        echo "JR-Bar's bundled daemon is missing: $CORE_BINARY" >&2
        exit 2
    fi
fi

run_as_user() {
    act /bin/launchctl asuser "$TARGET_UID" \
        /usr/bin/sudo -H -u "$TARGET_USER" \
        /usr/bin/env \
            HOME="$TARGET_HOME" \
            USER="$TARGET_USER" \
            LOGNAME="$TARGET_USER" \
            "$@"
}

# Remove only JR-Bar-owned integrations. Provider installers preserve every
# unrelated hook entry. An install from before the Swift app may still hold
# the retired menu bar's LaunchAgent: boot it out and unlink its plist.
for label in $RETIRED_AGENT_LABELS; do
    plist="$TARGET_HOME/Library/LaunchAgents/$label.plist"
    if [ -f "$plist" ] || [ -L "$plist" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            act /bin/launchctl bootout "gui/$TARGET_UID" "$plist"
        else
            /bin/launchctl bootout "gui/$TARGET_UID" "$plist" >/dev/null 2>&1 || true
        fi
        act /bin/rm -f "$plist"
    fi
done
run_as_user "$CORE_BINARY" agent-monitor uninstall all
run_as_user "$CORE_BINARY" sdejectguard uninstall --scope user

# System-owned helpers are removed only through their reviewed commands.
act /usr/bin/env \
    SUDO_USER="$TARGET_USER" \
    USER="$TARGET_USER" \
    LOGNAME="$TARGET_USER" \
    HOME="$TARGET_HOME" \
    "$CORE_BINARY" status-bar uninstall-sleep-helper
act "$CORE_BINARY" sdejectguard uninstall --scope system

# True when a link points into some JR-Bar bundle: this one, a moved one,
# a dev build, or the exact app executable an older package linked.
points_into_jrbar() {
    local destination
    destination="$(/usr/bin/readlink "$1")" || return 1
    case "$destination" in
        "$APP_BINARY") return 0 ;;
        */JR-Bar.app/Contents/*|*/JR-Bar-dev.app/Contents/*) return 0 ;;
        *) return 1 ;;
    esac
}

# The `jrbar` link: the user's ~/.local/bin one (what Settings installs)
# and the /usr/local/bin one older packages wrote, plus the pre-rename name.
if [ -n "${JRBAR_CLI_LINK:-${SIDEPULSE_CLI_LINK:-}}" ]; then
    CLI_LINKS="${JRBAR_CLI_LINK:-$SIDEPULSE_CLI_LINK}"
else
    CLI_LINKS="$TARGET_HOME/.local/bin/jrbar /usr/local/bin/jrbar"
fi
for link in $CLI_LINKS /usr/local/bin/sidepulse; do
    if [ -L "$link" ] && points_into_jrbar "$link"; then
        act /bin/rm -f "$link"
    elif [ -e "$link" ] || [ -L "$link" ]; then
        echo "Left existing $link unchanged because JR-Bar does not own it."
    fi
done

act /bin/rm -rf "$RECEIPT_DIR" "$LEGACY_RECEIPT_DIR"

if [ "$PURGE_STATE" -eq 1 ]; then
    act /bin/rm -rf \
        "$TARGET_HOME/.config/jrbar" \
        "$TARGET_HOME/.local/state/jrbar" \
        "$TARGET_HOME/.local/share/jrbar" \
        "$TARGET_HOME/Library/Application Support/JR-Bar" \
        "$TARGET_HOME/.config/sidepulse" \
        "$TARGET_HOME/.local/state/sidepulse" \
        "$TARGET_HOME/.local/share/sidepulse" \
        "$TARGET_HOME/Library/Application Support/SidePulse"
fi

if [ "$REMOVE_APP" -eq 1 ]; then
    act /bin/rm -rf "$APP_PATH"
fi

# Forget only the exact installer receipt owned by the supported JR-Bar PKG.
# Leaving it behind would make a verified clean reinstall indistinguishable
# from an upgrade at the package database boundary.
for package_id in "$PACKAGE_ID" "$LEGACY_PACKAGE_ID"; do
    if /usr/sbin/pkgutil --pkg-info "$package_id" >/dev/null 2>&1; then
        if [ "$DRY_RUN" -eq 1 ]; then
            act /usr/sbin/pkgutil --forget "$package_id"
        else
            /usr/sbin/pkgutil --forget "$package_id" >/dev/null
        fi
    fi
done

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "Dry run: nothing was removed for $TARGET_USER."
else
    printf '%s\n' "JR-Bar integrations removed for $TARGET_USER."
fi
