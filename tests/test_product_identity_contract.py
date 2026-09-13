from pathlib import Path

from jrbar.product_identity import PRODUCT_DISPLAY_NAME

ROOT = Path(__file__).resolve().parents[1]


def test_product_identity_uses_hyphenated_display_name__and_1_more() -> None:
    # --- scenario: product_identity_uses_hyphenated_display_name
    assert PRODUCT_DISPLAY_NAME == "JR-Bar"

    # --- scenario: current_source_and_public_docs_do_not_reintroduce_spaced_brand
    paths = [
        *((ROOT / "src" / "jrbar").glob("*.py")),
        ROOT / "README.md",
        *(ROOT / "docs").glob("*.md"),
    ]
    paths = [path for path in paths if path.name != "status_bar_legacy.py"]
    assert all("JR Bar" not in path.read_text(encoding="utf-8") for path in paths)

