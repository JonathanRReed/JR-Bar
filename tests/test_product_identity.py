from __future__ import annotations

from pathlib import Path

from jrbar.app_bundle import (
    APP_BUNDLE_IDENTIFIER,
    APP_BUNDLE_NAME,
    APP_EXECUTABLE_NAME,
)
from jrbar.cli import build_parser, build_sidepulse_parser
from jrbar.device_identity import DeviceKind, normalize_device_label
from jrbar.product_identity import PRODUCT_DISPLAY_NAME

ROOT = Path(__file__).resolve().parents[1]


def test_product_display_name_is_central_and_compatibility_identity_is_stable() -> None:
    assert PRODUCT_DISPLAY_NAME == "JR-Bar"
    assert APP_BUNDLE_NAME == "SidePulse.app"
    assert APP_EXECUTABLE_NAME == "SidePulse"
    assert APP_BUNDLE_IDENTIFIER == "io.sidepulse.app"
    assert normalize_device_label("ignored", DeviceKind.PRO) == "SidePulse Pro"
    assert normalize_device_label("ignored", DeviceKind.DOT) == "SidePulse Dot"


def test_cli_uses_jr_bar_display_name_and_preserves_command_name() -> None:
    parser = build_sidepulse_parser()

    assert parser.prog == "sidepulse"
    assert "JR-Bar" in parser.format_help()
    assert "SidePulse command line tools" not in parser.format_help()
    assert PRODUCT_DISPLAY_NAME in build_parser().format_help()


def test_macos_package_sets_display_name_without_renaming_bundle() -> None:
    script = (ROOT / "packaging" / "build_macos_pkg.sh").read_text(encoding="utf-8")

    assert ":CFBundleDisplayName string $PRODUCT_DISPLAY_NAME" in script
    assert ":CFBundleName string $PRODUCT_DISPLAY_NAME" in script
    assert "PRODUCT_DISPLAY_NAME=\"JR-Bar\"" in script
    assert "--name SidePulse" in script
    assert 'APP_ID="io.sidepulse.app"' in script


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
