from __future__ import annotations

import ast
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src" / "jrbar" / "status_bar.py"


def test_status_bar_adapters_preserve_originals_on_the_runtime_module__and_2_more() -> None:
    # --- scenario: status_bar_adapters_preserve_originals_on_the_runtime_module
    source = SOURCE.read_text(encoding="utf-8")
    for marker in (
        "_jrbar_original_device_id_for_root",
        "_jrbar_original_persistable_device_identity",
        "_jrbar_device_identity_cache",
    ):
        assert marker in source

    # --- scenario: status_bar_reload_does_not_replace_originals_with_its_own_wrappers
    normalized = " ".join(source.split())
    assert (
        'getattr( _legacy, "_jrbar_original_device_id_for_root", _legacy.device_id_for_root, )'
        in normalized
    )
    assert (
        'getattr( _legacy, "_jrbar_original_persistable_device_identity", _legacy.persistable_device_identity, )'
        in normalized
    )
    assert "_legacy._jrbar_device_identity_cache = cache" in source
    assert "def install_status_bar_facade" in source

    # --- scenario: device_identity_comes_from_the_cache_never_a_diskutil_fork
    calls = {
        node.func.attr if isinstance(node.func, ast.Attribute) else getattr(node.func, "id", "")
        for node in ast.walk(ast.parse(source))
        if isinstance(node, ast.Call)
    }
    assert "DeviceIdentityCache" in source
    assert "diskutil" not in source
    assert "subprocess" not in source
    assert "run" not in calls
