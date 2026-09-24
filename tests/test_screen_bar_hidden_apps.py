"""The Screen Bar's hidden-apps list (`screen_bar_hidden_apps`): the native
band steps aside while one of these apps is frontmost. The daemon only
carries the list, so it round-trips, reads tolerantly (a missing or
mistyped value is no apps), keeps bundle ids only, each once, and stays
bounded. The mock daemon serves the key so the app's card has a document
to read.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

from jrbar._settings_legacy import MAX_SCREEN_BAR_HIDDEN_APPS
from jrbar.settings import AgentMonitorSettings, load_settings, save_settings

ROOT = Path(__file__).resolve().parents[1]
MOCK_PATH = ROOT / "app" / "scripts" / "mock-core.py"


def test_hidden_apps_default_empty_and_round_trip(tmp_path: Path) -> None:
    assert AgentMonitorSettings().screen_bar_hidden_apps == ()
    assert AgentMonitorSettings().to_dict()["screen_bar_hidden_apps"] == []
    configured = AgentMonitorSettings().with_screen_bar_hidden_apps(
        ["com.apple.Keynote", "us.zoom.xos"]
    )
    path = tmp_path / "settings.json"
    save_settings(configured, path)
    assert load_settings(path).screen_bar_hidden_apps == ("com.apple.Keynote", "us.zoom.xos")


def test_hidden_apps_read_tolerantly(tmp_path: Path) -> None:
    path = tmp_path / "settings.json"
    for stored, expected in [
        ("com.apple.Keynote", ()),  # a bare string is not a list
        (None, ()),
        (7, ()),
        (["com.apple.Keynote", "com.apple.Keynote", 3, "", "not a bundle id!", " us.zoom.xos "],
         ("com.apple.Keynote", "us.zoom.xos")),
    ]:
        path.write_text(json.dumps({"screen_bar_hidden_apps": stored}))
        assert load_settings(path).screen_bar_hidden_apps == expected, stored


def test_hidden_apps_are_bounded() -> None:
    many = [f"com.example.app{index}" for index in range(MAX_SCREEN_BAR_HIDDEN_APPS + 10)]
    kept = AgentMonitorSettings().with_screen_bar_hidden_apps(many).screen_bar_hidden_apps
    assert len(kept) == MAX_SCREEN_BAR_HIDDEN_APPS
    assert kept[0] == "com.example.app0"


def test_mock_daemon_serves_the_key() -> None:
    spec = importlib.util.spec_from_file_location("mock_core_hidden_apps", MOCK_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
        assert module.default_settings_document()["screen_bar_hidden_apps"] == []
    finally:
        sys.modules.pop(spec.name, None)
