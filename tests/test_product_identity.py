from __future__ import annotations

from pathlib import Path

from jrbar.app_bundle import (
    APP_BUNDLE_IDENTIFIER,
    APP_BUNDLE_NAME,
    APP_EXECUTABLE_NAME,
    containing_app_bundle,
)
from jrbar.cli import build_jrbar_parser, build_parser
from jrbar.device_identity import DeviceKind, normalize_device_label
from jrbar.product_identity import PRODUCT_DISPLAY_NAME

ROOT = Path(__file__).resolve().parents[1]


def test_containing_app_bundle_accepts_main_and_nested_helper_layouts(tmp_path: Path) -> None:
    app = tmp_path / "JR-Bar.app"
    main = app / "Contents" / "MacOS" / "JR-Bar"
    helper = app / "Contents" / "Helpers" / "jrbar-core.app" / "Contents" / "MacOS" / "jrbar-core"
    main.parent.mkdir(parents=True)
    helper.parent.mkdir(parents=True)

    assert containing_app_bundle(main) == app
    assert containing_app_bundle(helper) == app


def test_containing_app_bundle_rejects_near_names_and_paths_without_contents(tmp_path: Path) -> None:
    near_name = tmp_path / "JR-Bar.app-copy" / "Contents" / "MacOS" / "JR-Bar"
    source_like = tmp_path / "JR-Bar.app" / "src" / "jrbar-core"
    bare_helper = tmp_path / "jrbar-core.app" / "Contents" / "MacOS" / "jrbar-core"
    near_name.parent.mkdir(parents=True)
    source_like.parent.mkdir(parents=True)
    bare_helper.parent.mkdir(parents=True)

    assert containing_app_bundle(near_name) is None
    assert containing_app_bundle(source_like) is None
    assert containing_app_bundle(bare_helper) is None


def test_product_display_name_and_bundle_identity_are_jr_bar__and_2_more() -> None:
    # --- scenario: product_display_name_and_bundle_identity_are_jr_bar
    assert PRODUCT_DISPLAY_NAME == "JR-Bar"
    assert APP_BUNDLE_NAME == "JR-Bar.app"
    assert APP_EXECUTABLE_NAME == "JR-Bar"
    assert APP_BUNDLE_IDENTIFIER == "com.jonathanreed.jrbar"
    # Hardware names are not software identity and never follow the rename.
    assert normalize_device_label("ignored", DeviceKind.PRO) == "SidePulse Pro"
    assert normalize_device_label("ignored", DeviceKind.DOT) == "SidePulse Dot"

    # --- scenario: cli_uses_jr_bar_display_name_and_command_name
    parser = build_jrbar_parser()

    assert parser.prog == "jrbar"
    assert "JR-Bar" in parser.format_help()
    assert "SidePulse command line tools" not in parser.format_help()
    assert PRODUCT_DISPLAY_NAME in build_parser().format_help()

    # --- scenario: macos_package_uses_jr_bar_bundle_identity
    script = (ROOT / "packaging" / "build_macos_pkg.sh").read_text(encoding="utf-8")

    assert ":CFBundleDisplayName string $PRODUCT_DISPLAY_NAME" in script
    assert ":CFBundleName string $PRODUCT_DISPLAY_NAME" in script
    assert "PRODUCT_DISPLAY_NAME=\"JR-Bar\"" in script
    assert "--name jrbar-core" in script
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
