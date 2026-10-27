"""Menu bar presentation uses display names, never stored identities."""
import re
from pathlib import Path


def test_menu_bar_labels_do_not_render_raw_owner_names():
    directory = Path(__file__).resolve().parents[1] / "app/Sources/JRBarApp/Utilities/MenuBar"
    raw_label = re.compile(
        r"Text\([^\n]*\.ownerName|(?:title|name): [^\n]*\.ownerName"
        r'|return "[^\n]*\\\([^\n]*\.ownerName'
    )
    violations = []
    for path in directory.glob("*.swift"):
        if path.name == "MenuBarItemLister.swift":
            continue  # Stable identity construction is separate from presentation.
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if raw_label.search(line):
                violations.append(f"{path.name}:{number}: use the item's displayName")
    assert not violations, "\n".join(violations)
