#!/bin/sh
# Launches the JR-Bar core daemon from this checkout's virtualenv.
#
# The Swift app runs this as its supervised child when JRBAR_CORE_EXEC names
# it (see docs/CORE-PROTOCOL.md, "Running it"). JRBAR_CORE_SOCKET, when set,
# is passed through as --socket so the app and the daemon agree on the path.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${JRBAR_PYTHON:-$HERE/.venv/bin/python}"
cd "$HERE"
export PYTHONUNBUFFERED=1
if [ -n "${JRBAR_CORE_SOCKET:-}" ]; then
    exec "$PYTHON" -m jrbar core --socket "$JRBAR_CORE_SOCKET" "$@"
fi
exec "$PYTHON" -m jrbar core "$@"
