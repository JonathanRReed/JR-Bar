#!/bin/bash
set -euo pipefail

APP_PATH="${JRBAR_APP_PATH:-${SIDEPULSE_APP_PATH:-/Applications/JR-Bar.app}}"
# The Swift app takes no arguments; the command line is the bundled daemon.
APP_BINARY="$APP_PATH/Contents/MacOS/JR-Bar"
CORE_BINARY="$APP_PATH/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core"
# The retired Python menu bar's LaunchAgent, and its pre-rename labels.
RETIRED_AGENT_LABELS="com.jonathanreed.jrbar.app io.sidepulse.agentstatus com.sidepulse.agentstatus"
CLI_LINK="${JRBAR_CLI_LINK:-${SIDEPULSE_CLI_LINK:-/usr/local/bin/jrbar}}"
# Link and receipts written by the pre-rename package; removed when ours.
LEGACY_CLI_LINK="/usr/local/bin/sidepulse"
RECEIPT_DIR="${JRBAR_RECEIPT_DIR:-${SIDEPULSE_RECEIPT_DIR:-/var/db/jrbar}}"
LEGACY_RECEIPT_DIR="/var/db/sidepulse"
PACKAGE_ID="com.jonathanreed.jrbar"
LEGACY_PACKAGE_ID="io.sidepulse.app"
PURGE_STATE=0
REMOVE_APP=1
TARGET_USER="${JRBAR_USER:-${SIDEPULSE_USER:-}}"

usage() {
    cat <<'EOF'
Usage: sudo ./scripts/uninstall-macos.sh [options]

  --user NAME    Remove user-owned JR-Bar integrations for NAME.
  --keep-app     Keep /Applications/JR-Bar.app.
  --purge-state  Also remove JR-Bar settings, logs, and local history.
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
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
    echo "Run the macOS uninstaller with sudo." >&2
    exit 2
fi

if [ -z "$TARGET_USER" ]; then
    TARGET_USER="$(/usr/bin/stat -f '%Su' /dev/console)"
fi
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ] || [ "$TARGET_USER" = "loginwindow" ]; then
    echo "Specify the JR-Bar user with --user NAME." >&2
    exit 2
fi

TARGET_UID="$(/usr/bin/id -u "$TARGET_USER")"
TARGET_HOME="$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "Could not resolve a safe home directory for $TARGET_USER." >&2
    exit 2
fi

if [ ! -x "$CORE_BINARY" ]; then
    echo "JR-Bar's bundled daemon is missing: $CORE_BINARY" >&2
    exit 2
fi

run_as_user() {
    /bin/launchctl asuser "$TARGET_UID" \
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
        /bin/launchctl bootout "gui/$TARGET_UID" "$plist" >/dev/null 2>&1 || true
        /bin/rm -f "$plist"
    fi
done
run_as_user "$CORE_BINARY" agent-monitor uninstall all
run_as_user "$CORE_BINARY" sdejectguard uninstall --scope user

# System-owned helpers are removed only through their reviewed commands.
/usr/bin/env \
    SUDO_USER="$TARGET_USER" \
    USER="$TARGET_USER" \
    LOGNAME="$TARGET_USER" \
    HOME="$TARGET_HOME" \
    "$CORE_BINARY" status-bar uninstall-sleep-helper
"$CORE_BINARY" sdejectguard uninstall --scope system

# Remove a CLI link only if it is the exact link an older package created
# (current name, or the pre-rename name, pointing at the app executable).
for link in "$CLI_LINK" "$LEGACY_CLI_LINK"; do
    if [ -L "$link" ] && [ "$(/usr/bin/readlink "$link")" = "$APP_BINARY" ]; then
        /bin/rm -f "$link"
    elif [ -e "$link" ] || [ -L "$link" ]; then
        echo "Left existing $link unchanged because JR-Bar does not own it."
    fi
done

/bin/rm -rf "$RECEIPT_DIR" "$LEGACY_RECEIPT_DIR"

if [ "$PURGE_STATE" -eq 1 ]; then
    /bin/rm -rf \
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
    /bin/rm -rf "$APP_PATH"
fi

# Forget only the exact installer receipt owned by the supported JR-Bar PKG.
# Leaving it behind would make a verified clean reinstall indistinguishable
# from an upgrade at the package database boundary.
for package_id in "$PACKAGE_ID" "$LEGACY_PACKAGE_ID"; do
    if /usr/sbin/pkgutil --pkg-info "$package_id" >/dev/null 2>&1; then
        /usr/sbin/pkgutil --forget "$package_id" >/dev/null
    fi
done

printf '%s\n' "JR-Bar integrations removed for $TARGET_USER."
