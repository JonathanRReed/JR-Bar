from __future__ import annotations

from pathlib import Path

from jrbar.app_bundle import (
    APP_BUNDLE_IDENTIFIER,
    APP_BUNDLE_NAME,
    APP_EXECUTABLE_NAME,
)
from jrbar.cli import build_jrbar_parser, build_parser
from jrbar.device_identity import DeviceKind, normalize_device_label
from jrbar.product_identity import PRODUCT_DISPLAY_NAME

ROOT = Path(__file__).resolve().parents[1]


def test_product_display_name_and_bundle_identity_are_jr_bar() -> None:
    assert PRODUCT_DISPLAY_NAME == "JR-Bar"
    assert APP_BUNDLE_NAME == "JR-Bar.app"
    assert APP_EXECUTABLE_NAME == "JR-Bar"
    assert APP_BUNDLE_IDENTIFIER == "com.jonathanreed.jrbar"
    # Hardware names are not software identity and never follow the rename.
    assert normalize_device_label("ignored", DeviceKind.PRO) == "SidePulse Pro"
    assert normalize_device_label("ignored", DeviceKind.DOT) == "SidePulse Dot"


def test_cli_uses_jr_bar_display_name_and_command_name() -> None:
    parser = build_jrbar_parser()

    assert parser.prog == "jrbar"
    assert "JR-Bar" in parser.format_help()
    assert "SidePulse command line tools" not in parser.format_help()
    assert PRODUCT_DISPLAY_NAME in build_parser().format_help()


def test_macos_package_uses_jr_bar_bundle_identity() -> None:
    script = (ROOT / "packaging" / "build_macos_pkg.sh").read_text(encoding="utf-8")

    assert ":CFBundleDisplayName string $PRODUCT_DISPLAY_NAME" in script
    assert ":CFBundleName string $PRODUCT_DISPLAY_NAME" in script
    assert "PRODUCT_DISPLAY_NAME=\"JR-Bar\"" in script
    assert "--name JR-Bar" in script
    assert 'APP_ID="com.jonathanreed.jrbar"' in script
    assert "io.sidepulse" not in script


def test_current_product_copy_has_no_retired_jr_bar_spelling() -> None:
    current_surfaces = (
        ROOT / "README.md",
        ROOT / "CHANGELOG.md",
        ROOT / "docs" / "FEATURE-MATRIX.md",
    )

    for path in current_surfaces:
        text = path.read_text(encoding="utf-8")
        assert "JR-BAR" not in text, path
        assert PRODUCT_DISPLAY_NAME in text, path
