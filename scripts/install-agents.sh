#!/bin/zsh
# Deploys JR-Bar on this Mac in one of two layouts.
#
# Default (development): this checkout as two LaunchAgents:
#
#   com.jonathanreed.jrbar.core  ->  ~/.local/share/jrbar/venv/bin/python -m jrbar core
#   com.jonathanreed.jrbar.ui    ->  ~/Applications/JR-Bar.app
#
# Everything launchd runs lives OUTSIDE ~/Downloads: the package is installed
# (non-editable) into ~/.local/share/jrbar/venv, the hook shim is copied to
# ~/.local/share/jrbar/bin/jrbar-hook and the app bundle to ~/Applications.
# A launchd job that reads a checkout under ~/Downloads blocks on a
# "would like to access files in your Downloads folder" TCC prompt for both
# the app bundle and the python interpreter; the installed copies never
# touch that folder, so there is no prompt to answer.
#
# launchd keeps both agents alive (KeepAlive); the app connects to
# ~/.local/state/jrbar/core.sock and reconnects with backoff whenever the
# daemon restarts. The daemon's doctor document reports the commit it was
# installed from (JRBAR_COMMIT). Every provider's hooks are re-pointed at
# the installed shim (`jrbar agent-monitor install all`).
#
# --pkg [SOURCE] (the packaged app): installs the bundle `make package`
# built, boots out and parks both LaunchAgents, and launches the app, which
# supervises the daemon it carries (Contents/Helpers/jrbar-core.app), points
# every provider's hooks at its shim (Contents/Helpers/jrbar-hook) on the
# first launch of a build, and registers itself as a login item. SOURCE is
# dist/JR-Bar-<version>.pkg (installed for this user with `installer
# -target CurrentUserHomeDirectory`, no password) or a JR-Bar.app (copied);
# the default is the PKG when it exists, else build/macos-pkg/app/JR-Bar.app.
# Either way the app lands in ~/Applications/JR-Bar.app; the /Applications
# install is `sudo installer -pkg dist/JR-Bar-<version>.pkg -target /`.
#
# Re-run after every commit you want running. Revert to the Python UI:
#   launchctl bootout gui/$UID/com.jonathanreed.jrbar.ui
#   launchctl bootout gui/$UID/com.jonathanreed.jrbar.core
#   .venv/bin/python -m jrbar status-bar start
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${JRBAR_INSTALL_PREFIX:-$HOME/.local/share/jrbar}"
VENV="$PREFIX/venv"
PYTHON="$VENV/bin/python"
SHIM_SRC="$ROOT/hook/build/jrbar-hook"
SHIM="$PREFIX/bin/jrbar-hook"
APP_SRC="$ROOT/app/build/JR-Bar.app"
APP="$HOME/Applications/JR-Bar.app"
BINARY="$APP/Contents/MacOS/JR-Bar"
CORE_LABEL="com.jonathanreed.jrbar.core"
UI_LABEL="com.jonathanreed.jrbar.ui"
OLD_LABEL="com.jonathanreed.jrbar.app"
AGENTS="$HOME/Library/LaunchAgents"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/jrbar"
DOMAIN="gui/$(id -u)"
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git -C "$ROOT" status --porcelain 2>/dev/null | grep -q . && echo '-dirty' || true)"
VERSION="$(sed -n 's/^version = "\([^"]*\)"$/\1/p' "$ROOT/pyproject.toml" | head -1)"

MODE="dev"
PKG_SOURCE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pkg)
            MODE="pkg"
            if [[ $# -gt 1 && "$2" != --* ]]; then PKG_SOURCE="$2"; shift; fi
            ;;
        -h|--help)
            sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$AGENTS" "$STATE" "$PREFIX/bin" "$HOME/Applications"

stop_everything() {
    # The Python status bar, the dev agents and a packaged app cannot share
    # the hook sockets: stop whatever is running before switching layouts.
    if launchctl print "$DOMAIN/$OLD_LABEL" >/dev/null 2>&1; then
        echo "==> booting out $OLD_LABEL"
        launchctl bootout "$DOMAIN/$OLD_LABEL" || true
    fi
    if [[ -f "$AGENTS/$OLD_LABEL.plist" ]]; then
        mv "$AGENTS/$OLD_LABEL.plist" "$STATE/$OLD_LABEL.plist.disabled"
        echo "moved $AGENTS/$OLD_LABEL.plist to $STATE/$OLD_LABEL.plist.disabled"
    fi
    for label in "$UI_LABEL" "$CORE_LABEL"; do
        launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    done
    # A JR-Bar or daemon started by hand would fight for the sockets.
    pkill -x "JR-Bar" 2>/dev/null || true
    pkill -f "jrbar core" 2>/dev/null || true
    pkill -f "jrbar-core core" 2>/dev/null || true
    pkill -f "jrbar status-bar" 2>/dev/null || true
    sleep 1
}

# A packaged app registers itself as a login item; hand that back before the
# dev LaunchAgents take over, or both would start an app at login.
login_item() {
    local bundle="$1" request="$2"
    if [[ -x "$bundle/Contents/MacOS/JR-Bar" && -x "$bundle/Contents/Helpers/jrbar-hook" ]]; then
        JRBAR_LOGIN_ITEM="$request" "$bundle/Contents/MacOS/JR-Bar" 2>/dev/null || true
    fi
}

wait_for_socket() {
    for _ in $(seq 30); do
        [[ -S "$STATE/core.sock" ]] && return 0
        sleep 1
    done
    echo "core.sock not up yet" >&2
    return 1
}

if [[ "$MODE" == "pkg" ]]; then
    if [[ -z "$PKG_SOURCE" ]]; then
        if [[ -f "$ROOT/dist/JR-Bar-$VERSION.pkg" ]]; then
            PKG_SOURCE="$ROOT/dist/JR-Bar-$VERSION.pkg"
        else
            PKG_SOURCE="$ROOT/build/macos-pkg/app/JR-Bar.app"
        fi
    fi
    [[ -e "$PKG_SOURCE" ]] || { echo "nothing to install at $PKG_SOURCE: run make package" >&2; exit 1; }

    stop_everything
    for label in "$UI_LABEL" "$CORE_LABEL"; do
        if [[ -f "$AGENTS/$label.plist" ]]; then
            mv "$AGENTS/$label.plist" "$STATE/$label.plist.disabled"
            echo "parked $AGENTS/$label.plist at $STATE/$label.plist.disabled"
        fi
    done
    rm -rf "$APP"

    case "$PKG_SOURCE" in
        *.pkg)
            echo "==> installing $PKG_SOURCE into ~/Applications (home-directory install, no password)"
            installer -pkg "$PKG_SOURCE" -target CurrentUserHomeDirectory
            ;;
        *.app)
            echo "==> copying $PKG_SOURCE to $APP"
            ditto "$PKG_SOURCE" "$APP"
            ;;
        *) echo "SOURCE must be a .pkg or a JR-Bar.app: $PKG_SOURCE" >&2; exit 2 ;;
    esac
    [[ -x "$BINARY" ]] || { echo "install did not produce $BINARY" >&2; exit 1; }
    [[ -x "$APP/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core" ]] || { echo "$APP carries no bundled daemon" >&2; exit 1; }
    codesign --verify --deep --strict "$APP" && echo "codesign verify: ok"
    echo "installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :JRBarCommit' "$APP/Contents/Info.plist" 2>/dev/null || echo 'no commit'))"

    echo "==> launch at login: $(JRBAR_LOGIN_ITEM=on "$BINARY" 2>/dev/null || echo 'could not register')"
    echo "==> launching $APP"
    open -a "$APP"
    wait_for_socket || true
    sleep 3
    app_pid="$(pgrep -x JR-Bar | head -1 || true)"
    if [[ -n "$app_pid" ]]; then
        echo "process tree:"
        ps -o pid=,ppid=,command= -p "$app_pid" | sed 's/^/  /'
        pgrep -P "$app_pid" | while read -r child; do ps -o pid=,ppid=,command= -p "$child" | sed 's/^/    /'; done
    else
        echo "JR-Bar is not running; see: log show --last 2m --predicate 'process == \"JR-Bar\"'" >&2
    fi
    echo "hooks (from the bundled daemon):"
    "$APP/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core" hooks doctor 2>/dev/null | grep -E '^  [a-z]+ ' | sed 's/^/  /' || true
    exit 0
fi

[[ -x "$APP_SRC/Contents/MacOS/JR-Bar" ]] || { echo "build the app first: app/scripts/build-app.sh" >&2; exit 1; }
[[ -x "$SHIM_SRC" ]] || { echo "build the shim first: hook/build.sh" >&2; exit 1; }
command -v uv >/dev/null || { echo "uv is required (brew install uv)" >&2; exit 1; }

echo "==> installing jrbar $COMMIT$DIRTY into $VENV"
[[ -x "$PYTHON" ]] || uv venv --python 3.12 --quiet "$VENV"
uv pip install --python "$PYTHON" --quiet --reinstall-package jrbar "$ROOT"
"$PYTHON" -c "import jrbar" || { echo "installed package does not import" >&2; exit 1; }
printf '%s\n' "$COMMIT$DIRTY" > "$PREFIX/COMMIT"

echo "==> installing the hook shim at $SHIM"
install -m 755 "$SHIM_SRC" "$SHIM"

stop_everything
login_item "$APP" off
echo "==> installing $APP"
rm -rf "$APP"
ditto "$APP_SRC" "$APP"
codesign --verify --deep --strict "$APP" && echo "codesign verify: ok"

write_plist() {
    local label="$1" out="$2"; shift 2
    local args=""
    for word in "$@"; do args+="		<string>$word</string>
"
    done
    cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
$args	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PYTHONUNBUFFERED</key>
		<string>1</string>
		<key>PATH</key>
		<string>/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>JRBAR_HOOK_EXEC</key>
		<string>$SHIM</string>
		<key>JRBAR_COMMIT</key>
		<string>$COMMIT$DIRTY</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>ExitTimeOut</key>
	<integer>10</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>WorkingDirectory</key>
	<string>$HOME</string>
	<key>StandardOutPath</key>
	<string>$STATE/${label##*.}.out.log</string>
	<key>StandardErrorPath</key>
	<string>$STATE/${label##*.}.err.log</string>
</dict>
</plist>
PLIST
    chmod 600 "$out"
    plutil -lint "$out" >/dev/null
}

echo "==> hooks: every provider runs $SHIM"
JRBAR_HOOK_EXEC="$SHIM" "$PYTHON" -m jrbar agent-monitor install all | grep -E '^[a-z]+:' || true

write_plist "$CORE_LABEL" "$AGENTS/$CORE_LABEL.plist" "$PYTHON" -m jrbar core
write_plist "$UI_LABEL" "$AGENTS/$UI_LABEL.plist" "$BINARY"

echo "==> loading $CORE_LABEL"
launchctl bootstrap "$DOMAIN" "$AGENTS/$CORE_LABEL.plist"
launchctl kickstart -k "$DOMAIN/$CORE_LABEL"
wait_for_socket || echo "see $STATE/core.err.log"

echo "==> loading $UI_LABEL"
launchctl bootstrap "$DOMAIN" "$AGENTS/$UI_LABEL.plist"
launchctl kickstart -k "$DOMAIN/$UI_LABEL"
sleep 3
for label in "$CORE_LABEL" "$UI_LABEL"; do
    printf '%s: ' "$label"
    launchctl print "$DOMAIN/$label" | grep -E '^\s+pid = ' | tr -d '\t' || echo "not running"
done
echo "installed $AGENTS/$CORE_LABEL.plist and $AGENTS/$UI_LABEL.plist (commit $COMMIT$DIRTY)"
