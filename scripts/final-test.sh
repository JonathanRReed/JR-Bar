#!/bin/bash
# Full source/package acceptance. No signing, publishing or hardware writes.
set -euo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOTSTRAP=1
ALLOW_DIRTY=0
usage() {
    printf '%s\n' 'Usage: scripts/final-test.sh [--no-bootstrap] [--allow-dirty]' \
        'Run the fast gate, full Mac suite, build, and clean-install checks.' \
        'Logs, commit identity and the final JUnit report stay in .jrbar-verification/.' \
        'The result does not certify physical hardware or a signed installed release.'
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-bootstrap) BOOTSTRAP=0 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done
if [ "$(uname -s)" != Darwin ]; then
    echo 'Final acceptance requires macOS. Use make test-portable on other systems.' >&2
    exit 2
fi
cd "$ROOT_DIR"
SOURCE_SHA="$(git rev-parse HEAD)"
SOURCE_STATUS="$(git status --porcelain)"
if [ -n "$SOURCE_STATUS" ] && [ "$ALLOW_DIRTY" -ne 1 ]; then
    echo 'Commit or stash local changes first, or use --allow-dirty for an explicitly non-candidate test run.' >&2
    exit 2
fi
mkdir -p .jrbar-verification
REPORT_DIR="$(mktemp -d "$ROOT_DIR/.jrbar-verification/$(date -u +%Y%m%dT%H%M%SZ)-${SOURCE_SHA:0:12}-XXXXXX")"
printf 'commit=%s\nbranch=%s\nallow_dirty=%s\nstatus=%s\n' \
    "$SOURCE_SHA" "$(git branch --show-current)" "$ALLOW_DIRTY" "$SOURCE_STATUS" > "$REPORT_DIR/source.txt"
sw_vers > "$REPORT_DIR/macos.txt"
trap 'code=$?; printf "%s\n" "$code" > "$REPORT_DIR/exit-code.txt"; printf "Verification records: %s\n" "$REPORT_DIR"' EXIT
VENV_DIR="${JRBAR_DEV_VENV:-${SIDEPULSE_DEV_VENV:-${VENV_DIR:-$ROOT_DIR/.venv}}}"
{
    if [ "$BOOTSTRAP" -eq 1 ]; then
        # Bootstrap uses the caller's base Python, not an as-yet absent venv.
        ./scripts/bootstrap-dev.sh
        PYTHON="$VENV_DIR/bin/python"
    else
        PYTHON="${PYTHON:-$VENV_DIR/bin/python}"
    fi
    export PYTHON
    "$PYTHON" -m pip freeze > "$REPORT_DIR/environment.txt"
    PYTEST_ADDOPTS= "$PYTHON" scripts/verify_fast.py
    junit_argument="$("$PYTHON" -c 'import shlex,sys; print(shlex.quote("--junitxml=" + sys.argv[1]))' "$REPORT_DIR/tests.xml")"
    PYTEST_ADDOPTS="$junit_argument" \
        JRBAR_VERIFY_MACOS_PACKAGE=0 ./scripts/verify.sh --no-bootstrap
    # Attribute success only to unchanged source bytes, not a moving checkout.
    test "$(git rev-parse HEAD)" = "$SOURCE_SHA"
    test "$(git status --porcelain)" = "$SOURCE_STATUS"
    echo 'Source, full Mac suite and package checks passed. Physical-device and signed-release checks remain separate.'
} 2>&1 | tee "$REPORT_DIR/run.log"
