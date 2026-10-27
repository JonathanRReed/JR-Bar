#!/bin/bash
# Source this after ROOT_DIR is set. Keep worktree imports in the worktree.
if [ -z "${PYTHON:-}" ]; then
    _jrbar_venv="${JRBAR_DEV_VENV:-${SIDEPULSE_DEV_VENV:-${VENV_DIR:-$ROOT_DIR/.venv}}}"
    PYTHON="$_jrbar_venv/bin/python"
    if [ ! -x "$PYTHON" ] && [ "$_jrbar_venv" = "$ROOT_DIR/.venv" ]; then
        _jrbar_common="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
        if [ -n "$_jrbar_common" ] && [ -x "${_jrbar_common%/*}/.venv/bin/python" ]; then
            PYTHON="${_jrbar_common%/*}/.venv/bin/python"
        fi
    fi
    if [ ! -x "$PYTHON" ]; then
        PYTHON="$(command -v python3.12 || command -v python3 || true)"
    fi
fi
PYTHON="$(command -v "$PYTHON" 2>/dev/null || printf '%s' "$PYTHON")"
export PYTHON
export PYTHONPATH="$ROOT_DIR/src${PYTHONPATH:+:$PYTHONPATH}"
if [ "${1:-}" = --print-python ]; then
    printf '%s\n' "$PYTHON"
fi
