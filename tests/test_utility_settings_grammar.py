"""Keep utility settings explanations beside their controls."""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from test_settings_duplicates import arguments

APP = Path(__file__).resolve().parents[1] / "app/Sources/JRBarApp"
CARDS = [
    "Utilities/Dock/DockUtilityCard.swift",
    "Utilities/Dock/DockPreviewSize.swift",
    "Utilities/KeepAwake/KeepAwakeUtilityCard.swift",
    "Utilities/MenuBar/MenuBarUtilityCard.swift",
    "Utilities/MenuBar/MenuBarCardRows.swift",
    "Utilities/Agents/AgentUtilityCard.swift",
    "Utilities/Agents/AgentAlertRulesTable.swift",
    "Toys/Fold/FoldToy.swift",
    "Toys/Aquarium/AquariumControls.swift",
    "Toys/Aquarium/AquariumSwimControls.swift",
    "Toys/NotchBuddyToy.swift",
    "Toys/NotchControlsView.swift",
    "Toys/ConfettiCard.swift",
    "Toys/Seasonal/SeasonalViews.swift",
]
SCOPES = [
    ("SettingsOrganizedPages.swift", "DeviceHardwareSettings"),
    ("SettingsOrganizedPages.swift", "ScreenBarMotionSettings"),
    ("SettingsPagesA.swift", "ScreenBarCard"),
    ("SettingsPagesA.swift", "NullableSlider"),
    ("SettingsPagesB.swift", "PowerGroup"),
    ("SettingsPagesShell.swift", "QuickTogglesGroup"),
    ("ScreenBarSettingsPreview.swift", "ScreenBarSettingsPreview"),
]


def missing_descriptions(text: str) -> list[str]:
    missing = []
    atoms = "SettingLabel|SettingToggle|SettingSlider|SettingPicker|SettingIntPicker|SettingStepper|SettingNumberField|SettingTextField|SettingRow|SettingsRow|NullableSlider"
    for match in re.finditer(r"\b(?:" + atoms + r")\s*\(", text):
        args = arguments(text, match.end())
        subtitle = next((arg for arg in args if arg.startswith("subtitle:")), "")
        if not subtitle or re.fullmatch(r'subtitle:\s*(?:nil|"")', subtitle):
            missing.append(args[0])
    return missing


@pytest.mark.parametrize("relative", CARDS)
def test_every_card_control_has_a_description(relative):
    assert not missing_descriptions((APP / relative).read_text()), relative


@pytest.mark.parametrize(("relative", "component"), SCOPES)
def test_shared_utility_controls_have_descriptions(relative, component):
    text = (APP / relative).read_text()
    start = re.search(r"^(?:private )?struct " + component + r"\b", text, re.MULTILINE)
    assert start is not None
    rest = text[start.end():]
    end = re.search(r"^(?:(?:private|public) )?(?:struct|enum|class|extension) ", rest, re.MULTILINE)
    body = rest[:end.start()] if end else rest
    assert not missing_descriptions(body), f"{relative}:{component}"


@pytest.mark.parametrize("subtitle", ["", ", subtitle: nil", ', subtitle: ""'])
def test_guard_rejects_a_control_without_an_explanation(subtitle):
    assert missing_descriptions(f'SettingLabel(title: "Synthetic setting"{subtitle})')


def test_dynamic_explanations_are_allowed():
    assert not missing_descriptions('SettingLabel(title: "Synthetic setting", subtitle: model.status)')


def test_dock_has_named_sections_and_searchable_widget_rows():
    card = (APP / "Utilities/Dock/DockUtilityCard.swift").read_text()
    for title in ["Previews", "App widgets", "Switchers", "Folders", "Exclusions"]:
        assert f'SettingGroup("{title}")' in card
    assert 'SettingsFeatureMoreOptions(id: "dock"' in card
    search = (APP / "Toys/ToySearchRows.swift").read_text().split('"dock": [', 1)[1].split('"agents": [', 1)[0]
    for title in [
        "Calendar preview", "Calendar view", "Mail preview", "Music player",
        "Full Music controls", "Reminders preview", "Shortcuts preview",
        "Messages preview", "Other media previews", "Folder pops",
        "Never switch to", "Hold the Dock out", "List past N windows",
        "⌥⇥ lists this display only",
    ]:
        assert f'ToySearchRow("{title}"' in search, title
