"""Audit Settings atoms and utility/toy labels without launching the app."""

from __future__ import annotations

import ast
import re
from collections import defaultdict
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1] / "app/Sources"
APP = ROOT / "JRBarApp"
ATOMS = {
    "SettingToggle", "SettingSlider", "SettingPicker", "SettingIntPicker",
    "SettingStepper", "SettingNumberField", "SettingTextField", "SettingLabel",
}


def arguments(text: str, start: int) -> list[str]:
    """Split a Swift call, keeping nested calls and string commas intact."""
    result: list[str] = []
    stack = [")"]
    quoted = escaped = False
    part = start
    for index in range(start, len(text)):
        char = text[index]
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char in "([{":
            stack.append({"(": ")", "[": "]", "{": "}"}[char])
        elif char in ")]}":
            assert char == stack.pop()
            if not stack:
                return [*result, text[part:index].strip()]
        elif char == "," and len(stack) == 1:
            result.append(text[part:index].strip())
            part = index + 1
    raise AssertionError("Unclosed Swift call")


def literal(expression: str) -> str | None:
    if not re.fullmatch(r'"(?:[^"\\]|\\.)*"', expression) or "\\(" in expression:
        return None
    expression = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda match: chr(int(match[1], 16)), expression)
    return ast.literal_eval(expression)


def inventory() -> list[dict[str, str]]:
    constants: dict[str, str] = {}
    for file in ROOT.rglob("*.swift"):
        text = file.read_text()
        pattern = r'static let (\w+)(?:\s*:\s*[\w.]+)?\s*=\s*("(?:[^"\\]|\\.)*")'
        for match in re.finditer(pattern, text):
            if (decoded := literal(match[2])) is not None:
                types = re.findall(r"\b(?:enum|struct|class)\s+(\w+)", text[:match.start()])
                owner = types[-1] if types else file.stem
                constants[f"{owner}.{match[1]}"] = decoded
                constants[f"{file.stem}.{match[1]}"] = decoded
    rows = []
    for file in sorted(APP.rglob("*.swift")):
        text = file.read_text()
        for match in re.finditer(r"\b(" + "|".join(sorted(ATOMS)) + r")\s*\(", text):
            args = arguments(text, match.end())
            named = dict(arg.split(":", 1) for arg in args if re.match(r"^\w+:\s", arg))
            named = {key: value.strip() for key, value in named.items()}
            title = named.get("title") if match[1] == "SettingLabel" else args[1] if len(args) > 1 else None
            if title is None or literal(title) is None:
                continue
            location = f"{file.relative_to(APP)}:{text[:match.start()].count(chr(10)) + 1}"
            path = named.get("path", "")
            # A parameter is a reusable atom, not another settings control.
            key = literal(path) or constants.get(path.removesuffix(".description"), location)
            subtitle = named.get("subtitle", "")
            rows.append({"key": key, "title": literal(title) or "",
                         "subtitle": literal(subtitle) or constants.get(subtitle, ""),
                         "location": location})
    return rows


# These short labels name the same operation in separately named feature cards.
# Their descriptions and surrounding cards identify different products or objects.
CONTEXTUAL_TITLES = {
    "Look": {"StudioLightPages.swift", "Toys/Fold/FoldToy.swift", "Toys/Aquarium/AquariumControls.swift"},
    "Size": {"Toys/NotchBuddyToy.swift", "Toys/ConfettiCard.swift"},
    "Sound": {"Toys/ConfettiCard.swift", "Toys/Aquarium/AquariumControls.swift"},
    "Render with": {"Toys/NotchControlsView.swift", "Toys/Fold/FoldToy.swift",
                    "Utilities/MenuBar/MenuBarUtilityCard.swift", "Utilities/Dock/DockUtilityCard.swift"},
}

# Fold's one slider helper chooses stepped or continuous, never both.
ALTERNATIVE_BINDINGS = {"Toys/Fold/FoldToy.swift:FoldControlsView:value": 2}


def test_settings_have_one_binding_and_distinct_words():
    rows = inventory()
    assert len(rows) > 200, "The audit must include Settings, Utilities and Toys."
    bindings: dict[str, list[str]] = defaultdict(list)
    words: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        if ":" not in row["key"]:
            bindings[row["key"]].append(row["location"])
        for field in ("title", "subtitle"):
            if row[field]:
                words[field, row[field]].append(row)
    duplicates = {key: locations for key, locations in bindings.items() if len(locations) > 1}
    assert not duplicates, f"Duplicate Settings bindings: {duplicates}"
    collisions = {}
    for (field, word), matches in words.items():
        if len({row["key"] for row in matches}) < 2:
            continue
        files = {row["location"].rsplit(":", 1)[0] for row in matches}
        if field == "title" and len(matches) == len(files) and files == CONTEXTUAL_TITLES.get(word):
            continue
        collisions[field, word] = [row["location"] for row in matches]
    assert not collisions, f"Different Settings keys share words: {collisions}"


def test_feature_index_only_navigates_and_details_own_the_switch():
    index = (APP / "Utilities/UtilitiesPage.swift").read_text()
    detail = (APP / "SettingsOrganizedPages.swift").read_text()
    assert "toy.isOn =" not in index
    assert detail.count("toy.isOn = $0") == 1


def test_display_choice_has_one_settings_binding():
    sources = "\n".join(file.read_text() for file in APP.rglob("*.swift"))
    assert sources.count("get: { toggles.awakeKeepsDisplay }") == 1


def test_raw_utility_and_toy_bindings_are_not_repeated():
    bindings: dict[str, list[str]] = defaultdict(list)
    files = {APP / row["location"].rsplit(":", 1)[0] for row in inventory()}
    for file in sorted(files):
        text = file.read_text()
        for match in re.finditer(r"\b(?:Toggle|Picker|Slider|Stepper|TextField)\s*\(", text):
            args = arguments(text, match.end())
            value = next((arg.split(":", 1)[1].strip() for arg in args
                          if re.match(r"^(?:isOn|selection|value|text):", arg)), "")
            getter = re.fullmatch(r"Binding\(get:\s*\{\s*([\w.]+)\s*\}.*", value, re.DOTALL)
            if getter:
                value = getter[1]
            if not re.fullmatch(r"\$?[\w.]+|\w+\.bind\(\\\.\w+\)", value):
                continue
            types = re.findall(r"\b(?:struct|class)\s+(\w+)", text[:match.start()])
            owner = types[-1] if types else file.stem
            key = f"{file.relative_to(APP)}:{owner}:{value}"
            if value == "toggles.awakeKeepsDisplay":
                key = "SystemTogglesStore.awakeKeepsDisplay"
            elif value.startswith("$store."):
                key = "SettingsStore." + value.removeprefix("$store.")
            location = f"{file.relative_to(APP)}:{text[:match.start()].count(chr(10)) + 1}"
            bindings[key].append(location)
    duplicates = {key: locations for key, locations in bindings.items()
                  if len(locations) > ALTERNATIVE_BINDINGS.get(key, 1)}
    assert not duplicates, f"Repeated utility or toy bindings: {duplicates}"
    for key, expected in ALTERNATIVE_BINDINGS.items():
        assert len(bindings[key]) == expected, f"Review the alternative binding allowance for {key}"


def test_inventory_reads_nested_calls_and_shared_descriptions():
    text = 'store, "One, two", subtitle: Help.words, path: choose("a", "b"))'
    assert arguments(text, 0) == ["store", '"One, two"', "subtitle: Help.words", 'path: choose("a", "b")']
    rows = inventory()
    assert any(row["title"] == "Keep the display on" and row["subtitle"] for row in rows)


@pytest.mark.parametrize("field", ["key", "title", "subtitle"])
def test_guard_rejects_a_new_duplicate(field, monkeypatch):
    rows = inventory()
    first = {"key": "synthetic_first", "title": "Synthetic first choice",
             "subtitle": "Synthetic first description", "location": "SyntheticFirst.swift:1"}
    second = {"key": "synthetic_second", "title": "Synthetic second choice",
              "subtitle": "Synthetic second description", "location": "SyntheticSecond.swift:1"}
    second[field] = first[field]
    monkeypatch.setitem(globals(), "inventory", lambda: [*rows, first, second])
    with pytest.raises(AssertionError, match=r"Duplicate Settings bindings|Different Settings keys share words"):
        test_settings_have_one_binding_and_distinct_words()
