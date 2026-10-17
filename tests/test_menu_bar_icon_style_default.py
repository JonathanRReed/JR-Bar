"""The daemon and the app agree on the menu bar icon style.

The daemon keeps the choice (``menu_bar_icon_style``) and the app draws it
(``StatusIconStyle``). If their defaults differ, a fresh install shows one
look until the first settings frame and another after it. This reads the
Swift enum's source, so the two stay pinned to one answer.
"""

from __future__ import annotations

import re
from pathlib import Path

from jrbar.settings import (
    DEFAULT_MENU_BAR_ICON_STYLE,
    MENU_BAR_ICON_STYLES,
    AgentMonitorSettings,
    normalize_menu_bar_icon_style,
)

RENDERER = Path(__file__).resolve().parents[1] / "app/Sources/JRBarUI/StatusIconRenderer.swift"


def _swift_source() -> str:
    return RENDERER.read_text(encoding="utf-8")


def _swift_styles(source: str) -> list[str]:
    styles: list[str] = []
    start = source.index("public enum StatusIconStyle")
    source = source[start : source.index("public init(setting", start)]
    for match in re.finditer(r'^\s*case (\w+)(?: = "(\w+)")?\s*$', source, flags=re.MULTILINE):
        styles.append(match.group(2) or match.group(1))
    return styles


def test_the_daemon_default_is_the_apps_default() -> None:
    source = _swift_source()
    # `init(setting:)` ends in `default: self = .<style>`; that is the app's answer.
    fallback = re.search(r"default:\s*self = \.(\w+)", source)
    assert fallback is not None
    app_default = {"glyphRing": "glyph_ring", "glyphLabel": "glyph_label"}.get(fallback.group(1), fallback.group(1))
    assert DEFAULT_MENU_BAR_ICON_STYLE == app_default
    assert AgentMonitorSettings().menu_bar_icon_style == app_default
    assert normalize_menu_bar_icon_style(None) == app_default
    assert normalize_menu_bar_icon_style("neon") == app_default


def test_the_daemon_lists_every_style_the_app_can_write() -> None:
    assert set(_swift_styles(_swift_source())) == set(MENU_BAR_ICON_STYLES)
