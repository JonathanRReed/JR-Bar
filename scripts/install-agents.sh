#!/bin/zsh
# Deploys this checkout as the running JR-Bar on this Mac and (re)installs the
# two LaunchAgents:
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
# installed from (JRBAR_COMMIT). Hooks for claude and codex are re-pointed
# at the installed shim.
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

[[ -x "$APP_SRC/Contents/MacOS/JR-Bar" ]] || { echo "build the app first: app/scripts/build-app.sh" >&2; exit 1; }
[[ -x "$SHIM_SRC" ]] || { echo "build the shim first: hook/build.sh" >&2; exit 1; }
command -v uv >/dev/null || { echo "uv is required (brew install uv)" >&2; exit 1; }
mkdir -p "$AGENTS" "$STATE" "$PREFIX/bin" "$HOME/Applications"

echo "==> installing jrbar $COMMIT$DIRTY into $VENV"
[[ -x "$PYTHON" ]] || uv venv --python 3.12 --quiet "$VENV"
uv pip install --python "$PYTHON" --quiet --reinstall-package jrbar "$ROOT"
"$PYTHON" -c "import jrbar" || { echo "installed package does not import" >&2; exit 1; }
printf '%s\n' "$COMMIT$DIRTY" > "$PREFIX/COMMIT"

echo "==> installing the hook shim at $SHIM"
install -m 755 "$SHIM_SRC" "$SHIM"

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

# The Python status bar and the daemon cannot both own the hook sockets.
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
# A JR-Bar or daemon started by hand would fight the agents for the sockets.
pkill -x "JR-Bar" 2>/dev/null || true
pkill -f "jrbar core" 2>/dev/null || true
pkill -f "jrbar status-bar" 2>/dev/null || true
sleep 1

echo "==> hooks: claude and codex run $SHIM"
for provider in claude codex; do
    JRBAR_HOOK_EXEC="$SHIM" "$PYTHON" -m jrbar agent-monitor install "$provider" | head -1
done

write_plist "$CORE_LABEL" "$AGENTS/$CORE_LABEL.plist" "$PYTHON" -m jrbar core
write_plist "$UI_LABEL" "$AGENTS/$UI_LABEL.plist" "$BINARY"

echo "==> loading $CORE_LABEL"
launchctl bootstrap "$DOMAIN" "$AGENTS/$CORE_LABEL.plist"
launchctl kickstart -k "$DOMAIN/$CORE_LABEL"
for _ in $(seq 20); do
    [[ -S "$STATE/core.sock" ]] && break
    sleep 1
done
[[ -S "$STATE/core.sock" ]] || echo "core.sock not up yet; see $STATE/core.err.log"

echo "==> loading $UI_LABEL"
launchctl bootstrap "$DOMAIN" "$AGENTS/$UI_LABEL.plist"
launchctl kickstart -k "$DOMAIN/$UI_LABEL"
sleep 3
for label in "$CORE_LABEL" "$UI_LABEL"; do
    printf '%s: ' "$label"
    launchctl print "$DOMAIN/$label" | grep -E '^\s+pid = ' | tr -d '\t' || echo "not running"
done
echo "installed $AGENTS/$CORE_LABEL.plist and $AGENTS/$UI_LABEL.plist (commit $COMMIT$DIRTY)"
