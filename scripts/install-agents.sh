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
# Either way the app lands in ~/Applications/JR-Bar.app, registered with
# Launch Services so jrbar:// links open that copy; the /Applications
# install is `sudo installer -pkg dist/JR-Bar-<version>.pkg -target /`.
#
# Re-run after every commit you want running. To stop the dev layout:
#   launchctl bootout gui/$UID/com.jonathanreed.jrbar.ui
#   launchctl bootout gui/$UID/com.jonathanreed.jrbar.core
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
LSREGISTER="${LSREGISTER_TOOL:-/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister}"
PGREP="${PGREP_TOOL:-/usr/bin/pgrep}"
PS="${PS_TOOL:-/bin/ps}"
KILL="${KILL_TOOL:-/bin/kill}"
STOP_SLEEP="${STOP_SLEEP_TOOL:-/bin/sleep}"
RECOVERY_OPEN="${RECOVERY_OPEN_TOOL:-/usr/bin/open}"
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
            sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$AGENTS" "$STATE" "$PREFIX/bin" "$HOME/Applications"

stop_everything() {
    # The retired Python status bar, the dev agents and a packaged app
    # cannot share the hook sockets: stop whatever is running before
    # switching layouts.
    local executable stopped
    stop_started=1
    if launchctl print "$DOMAIN/$OLD_LABEL" >/dev/null 2>&1; then
        echo "==> booting out $OLD_LABEL"
        launchctl bootout "$DOMAIN/$OLD_LABEL" || true
    fi
    for label in "$UI_LABEL" "$CORE_LABEL"; do
        launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    done
    # Stop only a process whose executable is the installed app. This avoids
    # both broad process-name kills and an Apple Events permission prompt.
    while IFS= read -r pid; do
        [[ "$pid" == <-> ]] || continue
        executable="$("$PS" -p "$pid" -o comm= 2>/dev/null || true)"
        [[ "$executable" == "$BINARY" ]] || continue
        # Re-read immediately before signalling so a reused PID cannot turn
        # the first observation into a kill of another process.
        executable="$("$PS" -p "$pid" -o comm= 2>/dev/null || true)"
        [[ "$executable" == "$BINARY" ]] || continue
        if ! "$KILL" -TERM "$pid" 2>/dev/null; then
            echo "JR-Bar process $pid could not be stopped; the installed app was not moved." >&2
            return 1
        fi
        stopped_installed_app=1
        stopped=0
        for _ in {1..50}; do
            executable="$("$PS" -p "$pid" -o comm= 2>/dev/null || true)"
            if [[ "$executable" != "$BINARY" ]]; then
                stopped=1
                break
            fi
            "$STOP_SLEEP" 0.1
        done
        if [[ "$stopped" != 1 ]]; then
            echo "JR-Bar process $pid did not exit; the installed app was not moved." >&2
            return 1
        fi
    done < <("$PGREP" -x JR-Bar 2>/dev/null || true)
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
    [[ ! -L "$PKG_SOURCE" ]] || { echo "SOURCE must not be a symlink: $PKG_SOURCE" >&2; exit 2; }
    case "$PKG_SOURCE" in
        *.pkg)
            [[ -f "$PKG_SOURCE" ]] || { echo "SOURCE is not a regular package: $PKG_SOURCE" >&2; exit 2; }
            payload="$(/usr/sbin/pkgutil --payload-files "$PKG_SOURCE" | /usr/bin/sed 's#^\./##')" || {
                echo "SOURCE is not a readable macOS package: $PKG_SOURCE" >&2
                exit 2
            }
            for required in \
                JR-Bar.app/Contents/MacOS/JR-Bar \
                JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core \
                JR-Bar.app/Contents/Helpers/jrbar-hook; do
                print -r -- "$payload" | /usr/bin/grep -Fxq "$required" || {
                    echo "package payload is missing $required" >&2
                    exit 2
                }
            done
            validation_dir="$(/usr/bin/mktemp -d "$HOME/Applications/.jrbar-package-check.XXXXXX")"
            chmod 700 "$validation_dir"
            if ! /usr/sbin/pkgutil --expand "$PKG_SOURCE" "$validation_dir/expanded"; then
                /bin/rm -rf "$validation_dir"
                echo "SOURCE cannot be expanded as a macOS package: $PKG_SOURCE" >&2
                exit 2
            fi
            package_infos=("$validation_dir"/expanded/**/PackageInfo(N))
            if [[ "${#package_infos[@]}" -ne 1 ]] || \
               ! /usr/bin/grep -Eq '<pkg-info[^>]*identifier="com\.jonathanreed\.jrbar"' "$package_infos[1]"; then
                /bin/rm -rf "$validation_dir"
                echo "package identifier is not com.jonathanreed.jrbar" >&2
                exit 2
            fi
            /bin/rm -rf "$validation_dir"
            ;;
        *.app)
            [[ -d "$PKG_SOURCE" ]] || { echo "SOURCE is not an application bundle: $PKG_SOURCE" >&2; exit 2; }
            for required in \
                Contents/MacOS/JR-Bar \
                Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core \
                Contents/Helpers/jrbar-hook; do
                [[ -x "$PKG_SOURCE/$required" ]] || {
                    echo "application bundle is missing $required" >&2
                    exit 2
                }
            done
            source_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PKG_SOURCE/Contents/Info.plist" 2>/dev/null || true)"
            [[ "$source_identifier" == "com.jonathanreed.jrbar" ]] || {
                echo "application bundle has the wrong bundle identifier: ${source_identifier:-missing}" >&2
                exit 2
            }
            codesign --verify --deep --strict "$PKG_SOURCE" || {
                echo "application bundle signature is invalid: $PKG_SOURCE" >&2
                exit 2
            }
            ;;
        *) echo "SOURCE must be a .pkg or a JR-Bar.app: $PKG_SOURCE" >&2; exit 2 ;;
    esac

    staging="$(/usr/bin/mktemp -d "$HOME/Applications/.jrbar-install.XXXXXX")"
    chmod 700 "$staging"
    old_app="$staging/JR-Bar.app.previous"
    transaction_active=1
    old_app_moved=0
    replacement_started=0
    stop_started=0
    stopped_installed_app=0
    restore_install() {
        local result_code=$?
        if [[ "$transaction_active" == 1 && "$result_code" -ne 0 ]]; then
            echo "install failed; restoring the previous JR-Bar app and launch agents" >&2
            if [[ "$replacement_started" == 1 ]]; then
                [[ ! -e "$APP" && ! -L "$APP" ]] || /bin/rm -rf "$APP"
            fi
            if [[ "$old_app_moved" == 1 && -e "$old_app" ]]; then
                /bin/mv "$old_app" "$APP"
            fi
            for label in "$OLD_LABEL" "$UI_LABEL" "$CORE_LABEL"; do
                staged_plist="$staging/$label.plist"
                if [[ -e "$staged_plist" ]]; then
                    /bin/mv "$staged_plist" "$AGENTS/$label.plist"
                fi
                if [[ "$stop_started" == 1 && -f "$AGENTS/$label.plist" ]]; then
                    launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist" >/dev/null 2>&1 || true
                    launchctl kickstart -k "$DOMAIN/$label" >/dev/null 2>&1 || true
                fi
            done
            if [[ "$stopped_installed_app" == 1 && -d "$APP" ]]; then
                "$RECOVERY_OPEN" -a "$APP" >/dev/null 2>&1 || true
            fi
        fi
        /bin/rm -rf "$staging"
        return "$result_code"
    }
    trap restore_install EXIT

    stop_everything
    if [[ -e "$APP" || -L "$APP" ]]; then
        /bin/mv "$APP" "$old_app"
        old_app_moved=1
    fi
    for label in "$OLD_LABEL" "$UI_LABEL" "$CORE_LABEL"; do
        if [[ -f "$AGENTS/$label.plist" && ! -L "$AGENTS/$label.plist" ]]; then
            /bin/mv "$AGENTS/$label.plist" "$staging/$label.plist"
        fi
    done

    case "$PKG_SOURCE" in
        *.pkg)
            replacement_started=1
            echo "==> installing $PKG_SOURCE into ~/Applications (home-directory install, no password)"
            installer -pkg "$PKG_SOURCE" -target CurrentUserHomeDirectory
            ;;
        *.app)
            replacement_started=1
            echo "==> copying $PKG_SOURCE to $APP"
            ditto "$PKG_SOURCE" "$APP"
            ;;
    esac
    [[ -x "$BINARY" ]] || { echo "install did not produce $BINARY" >&2; exit 1; }
    [[ -x "$APP/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core" ]] || { echo "$APP carries no bundled daemon" >&2; exit 1; }
    [[ -x "$APP/Contents/Helpers/jrbar-hook" ]] || { echo "$APP carries no bundled hook shim" >&2; exit 1; }
    installed_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$installed_identifier" == "com.jonathanreed.jrbar" ]] || { echo "installed app has the wrong bundle identifier" >&2; exit 1; }
    if ! codesign --verify --deep --strict "$APP"; then
        echo "installed app signature verification failed" >&2
        exit 1
    fi
    echo "codesign verify: ok"

    # The replacement is verified. Keep the old development agents parked as
    # before, then discard the app backup and commit the transaction.
    for label in "$OLD_LABEL" "$UI_LABEL" "$CORE_LABEL"; do
        staged_plist="$staging/$label.plist"
        if [[ -e "$staged_plist" ]]; then
            /bin/mv "$staged_plist" "$STATE/$label.plist.disabled"
            echo "parked $AGENTS/$label.plist at $STATE/$label.plist.disabled"
        fi
    done
    /bin/rm -rf "$old_app"
    transaction_active=0
    echo "installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :JRBarCommit' "$APP/Contents/Info.plist" 2>/dev/null || echo 'no commit'))"
    # jrbar:// links open whichever copy Launch Services picks: make it
    # this one. The package build unregisters its own intermediates, but
    # the installer's look for an existing com.jonathanreed.jrbar puts
    # them straight back, so they come out again here.
    if [[ -x "$LSREGISTER" ]]; then
        for bundle in "$ROOT/build/macos-pkg/app/JR-Bar.app" "$ROOT/build/macos-pkg/swift/JR-Bar.app"; do
            [[ -e "$bundle" ]] && { "$LSREGISTER" -u "$bundle" >/dev/null 2>&1 || true; }
        done
        if "$LSREGISTER" -f "$APP" >/dev/null 2>&1; then
            echo "==> registered $APP with Launch Services"
        else
            echo "lsregister could not register $APP; jrbar:// links may open another copy" >&2
        fi
    fi

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
    /bin/rm -rf "$staging"
    trap - EXIT
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
if [[ -f "$AGENTS/$OLD_LABEL.plist" && ! -L "$AGENTS/$OLD_LABEL.plist" ]]; then
    mv "$AGENTS/$OLD_LABEL.plist" "$STATE/$OLD_LABEL.plist.disabled"
    echo "moved $AGENTS/$OLD_LABEL.plist to $STATE/$OLD_LABEL.plist.disabled"
fi
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
