from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_installer_uses_an_isolated_virtual_environment() -> None:
    text = (ROOT / "scripts" / "install-user.sh").read_text(encoding="utf-8")

    assert '"$PYTHON_BIN" -m venv "$VENV_DIR"' in text
    assert '"$VENV_DIR/bin/python" -m pip install' in text
    assert "--break-system-packages" not in text
