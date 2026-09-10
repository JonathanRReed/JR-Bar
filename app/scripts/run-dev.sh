#!/bin/zsh
# Runs a development copy of the app against the mock daemon, without
# touching the installed JR-Bar.app (the LaunchAgent com.jonathanreed.jrbar.ui
# on ~/.local/state/jrbar/core.sock).
#
# * The bundle is build/JR-Bar-dev.app, built here if missing (or always
#   with --build), so it never replaces the installed one.
# * The mock listens on $TMPDIR/jrbar-mock.sock (its default; it refuses the
#   real socket) and the app is pointed at it with JRBAR_CORE_SOCKET. The
#   timeline plays once; pass --loop to replay it (it makes sounds).
# * Nothing is killed by name: only the pids this script wrote to
#   build/dev.pids (its own previous mock and app) are stopped, and
#   `run-dev.sh --stop` stops them.
#
#   ./scripts/run-dev.sh                       # mock + app, panel closed
#   JRBAR_OPEN_CONTROL_CENTER=1 ./scripts/run-dev.sh --deck unapproved
#   JRBAR_DECK_RAIL=left ./scripts/run-dev.sh   # the rail on the left edge
#   ./scripts/run-dev.sh --stop
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$APP_DIR/build"
BUNDLE="$BUILD_DIR/JR-Bar-dev.app"
PIDS="$BUILD_DIR/dev.pids"
SOCKET="${JRBAR_CORE_SOCKET:-${TMPDIR:-/tmp}/jrbar-mock.sock}"
SOCKET="${SOCKET%/}"

stop_previous() {
    [[ -f "$PIDS" ]] || return 0
    local pids=()
    while read -r pid; do
        [[ -n "$pid" ]] && pids+=("$pid")
    done < "$PIDS"
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    # The mock notices SIGTERM within 0.25 s and unlinks its socket; a new
    # mock started before that refuses to replace a listening one.
    for _ in {1..30}; do
        local alive=0
        for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
        [[ $alive == 0 ]] && break
        sleep 0.1
    done
    for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
    rm -f "$PIDS"
}

if [[ "${1:-}" == "--stop" ]]; then
    stop_previous
    echo "stopped the dev mock and app"
    exit 0
fi

build=0
mock_args=()
for arg in "$@"; do
    case "$arg" in
        --build) build=1 ;;
        *) mock_args+=("$arg") ;;
    esac
done

case "$SOCKET" in
    "$HOME/.local/state/jrbar/core.sock"|"${XDG_STATE_HOME:-/nonexistent}/jrbar/core.sock")
        echo "refusing to point the dev app at the installed daemon's socket ($SOCKET)" >&2
        exit 2 ;;
esac

stop_previous
if [[ $build == 1 || ! -d "$BUNDLE" ]]; then
    JRBAR_BUNDLE="$BUNDLE" "$APP_DIR/scripts/build-app.sh"
fi

mkdir -p "$BUILD_DIR"
python3 "$APP_DIR/scripts/mock-core.py" --socket "$SOCKET" "${mock_args[@]}" > "$BUILD_DIR/dev-mock.log" 2>&1 &
mock_pid=$!
echo "$mock_pid" > "$PIDS"
for _ in {1..40}; do
    [[ -S "$SOCKET" ]] && break
    sleep 0.1
done
[[ -S "$SOCKET" ]] || { echo "mock did not create $SOCKET" >&2; exit 1; }

JRBAR_CORE_SOCKET="$SOCKET" "$BUNDLE/Contents/MacOS/JR-Bar" > "$BUILD_DIR/dev-app.log" 2>&1 &
app_pid=$!
echo "$app_pid" >> "$PIDS"
echo "mock pid $mock_pid on $SOCKET; app pid $app_pid from $BUNDLE (logs in $BUILD_DIR/dev-*.log; pids in $PIDS; --stop ends them)"
