from __future__ import annotations

import json
from pathlib import Path

import pytest

from scripts.check_design_tokens import BASELINE, differences, main, offenders, scan


@pytest.mark.parametrize("source,kind", [
    ("Text(\"x\").font(.system(size: 10))", "font"),
    ("Color(\n red: 0.2, green: 0.3, blue: 0.4)", "colour"),
    ("RoundedRectangle(cornerRadius: 9)", "radius"),
    ("view.cornerRadius(9)", "radius"),
    (".easeOut(duration: 0.14)", "animation"),
    (".spring(response: 0.3)", "animation"),
    ('Text("██░░")', "block-meter"),
])
def test_rejects_literal(source, kind):
    assert next(iter(offenders(source))).startswith(kind + ":")


def test_ignores_comments_strings_and_tokens():
    source = '''
    // .system(size: 10)
    /* outer /* Color(red: 1) */ .cornerRadius(8) */
    Text(".easeOut(duration: 0.1)")
    Text(#"Color(red: 1)"#)
    Text(""".system(size: 8)""")
    .font(JRBarTokens.TypeStyle.body.font)
    .clipShape(RoundedRectangle(cornerRadius: JRBarTokens.Radius.group))
    .animation(JRBarTokens.Motion.rowChange.animation, value: selected)
    '''
    assert not offenders(source)


def test_exception_needs_reason_on_the_same_line():
    assert not offenders(".system(size: 13) // jrbar-token-exception: token definition")
    assert offenders(".system(size: 13) // jrbar-token-exception:")
    assert offenders("// jrbar-token-exception: unrelated\n.system(size: 13)")
    assert offenders('Text("// jrbar-token-exception: fake").font(.system(size: 13))')


def test_replacement_cannot_trade_an_old_offender_for_a_new_one():
    assert differences({"a.swift": {"font: .system(size: 9": 1}}, {"a.swift": {"font: .system(size: 10": 1}})
    assert differences({"b.swift": {"radius: cornerRadius: 8": 1}}, {"a.swift": {"radius: cornerRadius: 8": 1}})


def test_prune_only_removes_allowances(tmp_path: Path):
    source = tmp_path / "app/Sources/Test.swift"
    source.parent.mkdir(parents=True)
    source.write_text(".system(size: 12)")
    baseline = tmp_path / BASELINE
    baseline.parent.mkdir()
    baseline.write_text(json.dumps(scan(tmp_path)))
    source.write_text(".system(size: 13)")
    assert main(["--root", str(tmp_path), "--prune"]) == 1
    assert json.loads(baseline.read_text()) == {}


def test_repository_matches_baseline():
    root = Path(__file__).resolve().parents[1]
    assert not differences(scan(root), json.loads((root / BASELINE).read_text()))


def test_overview_connections_use_shared_state_projections():
    root = Path(__file__).resolve().parents[1] / "app/Sources/JRBarApp"
    source = (root / "Overview/OverviewLinks.swift").read_text()
    assert "DeviceConnectionState.device(" in source
    assert "DeviceConnectionState.screenBar(" in source
    assert "DeviceConnectionState.creatorMicro(" in source
    assert "UsageStatus.provider(provider)" in source
    assert 'state.replacingOccurrences(of: "_", with: " ")' not in source
    for filename in ["Overview/OverviewStrips.swift", "Overview/OverviewInspector.swift"]:
        assert "link.tone.color" not in (root / filename).read_text()


def test_usage_overview_uses_shared_window_and_time_words():
    root = Path(__file__).resolve().parents[1] / "app/Sources"
    source = (root / "JRBarApp/UsageOverviewTable.swift").read_text()
    assert "UsageGaugeRow.compactWindowNames(" in source
    assert "UsageWindowLabel.column(" in source
    row = source.split("struct UsageOverviewProviderRow:", 1)[1].split("struct UsageOverviewHeader:", 1)[0]
    assert "includeAbsent: true" in row
    assert 'provider.availability == "absent"' not in row
    assert "UsageTime" not in source, "The table must not format its own countdowns"
    gauge = (root / "JRBarUI/UsageGaugeRow.swift").read_text()
    assert "reading.stale && reading.elapsed" in gauge
    assert "compactReadingStatus.padding(.leading, 30)" in gauge
    assert "Text(UsageStatus.noReading.word)" in gauge


def test_typography_migration_cannot_be_reopened_with_an_allowance():
    root = Path(__file__).resolve().parents[1]
    for file, hits in scan(root).items():
        # The notch is pinned; the divider lane owns the remaining Menu Bar files.
        if "/Notch/" in file or "/Utilities/MenuBar/" in file:
            continue
        assert not any(key.startswith(("font-floor:", "semantic-font:", "semantic-small:")) for key in hits), file


@pytest.mark.parametrize("source,kind", [
    ('Text("State").font(.caption)', "semantic-font"),
    ('Text("State").font(.caption2.weight(.medium))', "semantic-font"),
    ('Text("State").font(.system(.caption, design: .monospaced))', "semantic-small"),
    ('Text("State").font(.system(size: 10.5))', "font-floor"),
    ('Text("State").foregroundStyle(.orange)', "status-colour"),
    ('Text("State").foregroundStyle(Color.red)', "status-colour"),
    ('Text("State").foregroundStyle(.green)', "status-colour"),
    ('Text("\\(value) % left")', "spaced-percent"),
    ('String(format: "%.1f %%/h", rate)', "spaced-percent"),
    ('Text("\\(minutes) min")', "elapsed-unit"),
    ('String(format: "%d min", minutes)', "elapsed-unit"),
    ('String(format: "%02d:%02d", hour, minute)', "fixed-clock"),
    ('formatter.setLocalizedDateFormatFromTemplate("EEEj")', "missing-clock-minutes"),
    ('func currencySymbol(_ currency: String) -> String {}', "currency-table"),
    ('switch currency { case "EUR": "€"; default: "$" }', "currency-table"),
    ('let count = tokens / 1_000', "token-math"),
    ('Text("Monitor offline")', "monitor-wording"),
    ('Text("The monitor is not answering")', "monitor-wording"),
    ('statusItem.setCore(description: "disconnected · \\(reason)")', "monitor-wording"),
    ('PaletteItem(title: "Monitor Not Connected")', "monitor-wording"),
    ('NSAttributedString(string: "Monitor: \\(description)")', "monitor-wording"),
    ('Text("Effect Studio")', "ui-name"),
    ('Text("Blend mode")', "ui-name"),
    ('Text("42% left")', "usage-direction"),
    ('view.foregroundStyle(JRBarTokens.Ink.attention)', "quota-tone"),
    ('view.buttonStyle(PillButtonStyle(prominent: false))', "secondary-button"),
    ('Text("Turn it on in Settings \u203a Agents & Usage")', "retired-page"),
    ('let text = "Setup (Settings \u203a General) grants it back."', "retired-page"),
    ('let help = "under Settings \u203a General \u203a Power."', "retired-page"),
    ('self.show(toast: error.localizedDescription)', "error-words"),
    ('return SetupNote(String(describing: error), isError: true)', "error-words"),
    ('return reply.message ?? reply.code', "error-words"),
    ('let why = reply.error?.message ?? reply.error?.code ?? "refused"', "error-words"),
    ('report(error: "Install hooks: \\(error)")', "error-words"),
    ('return provider.reason?.replacingOccurrences(of: "_", with: " ") ?? action', "reason-code-words"),
    ('Button { pin() } label: {\n    Image(systemName: "pin")\n}\n.buttonStyle(.plain)', "icon-label"),
    ('Button(action: next) { Image(systemName: "chevron.right") }.help("Next page")', "icon-label"),
])
def test_rejects_ui_drift(source, kind):
    assert any(hit.startswith(kind + ":") for hit in offenders(source))


@pytest.mark.parametrize("source", [
    'Button { pin() } label: {\n    Image(systemName: "pin")\n}\n.accessibilityLabel("Pin key")',
    'Button { pin() } label: { Image(systemName: "pin"); Text("Pin") }',
    'Button { pin() } label: { Label("Pin", systemImage: "pin") }',
])
def test_named_icon_buttons_pass(source):
    assert not [hit for hit in offenders(source) if hit.startswith("icon-label:")]


def test_wording_and_notch_exceptions_are_narrow():
    source = 'Text("State").font(.caption).foregroundStyle(.orange)'
    assert not offenders(source, "app/Sources/JRBarApp/Toys/Notch/NotchCardView.swift")
    assert offenders(source, "app/Sources/JRBarApp/SettingsView.swift")
    assert not offenders('func currencySymbol() {}', "app/Sources/JRBarCore/Wording.swift")
    assert offenders('func currencySymbol() {}', "app/Sources/JRBarApp/Other.swift")
    assert not offenders('let label = "Monitor not connected"', "app/Sources/JRBarCore/StatusWords.swift")
    assert not offenders('let paint = model.red + model.green')
    assert not offenders('Text("42% left")', "app/Sources/JRBarUI/StatusIconRenderer.swift")
    assert offenders('Text("42% left")', "app/Sources/JRBarApp/UsageProviderDetail.swift")


@pytest.mark.parametrize("file,name", [
    ("PanelView.swift", "CountBadge"),
    ("PanelView.swift", "DeviceChip"),
    ("ControlCenterView.swift", "KeymapBadge"),
    ("EffectStudioView.swift", "Badge"),
    ("EffectStudioView.swift", "FactChip"),
    ("HistoryView.swift", "KindBadge"),
    ("Palette/PaletteView.swift", "PaletteTagView"),
    ("Overview/OverviewView.swift", "OverviewSnoozedTag"),
    ("Overview/OverviewStrips.swift", "OverviewCountPill"),
    ("Overview/OverviewInspector.swift", "OverviewStatePill"),
    ("Utilities/Dock/DockChrome.swift", "DockBadgePill"),
])
def test_status_badges_use_the_shared_renderer(file, name):
    root = Path(__file__).resolve().parents[1] / "app/Sources/JRBarApp"
    source = (root / file).read_text()
    declaration = source.split("struct " + name + ":", 1)[1].split("\n}\n", 1)[0]
    assert "StatusBadge(" in declaration
    assert "Capsule()" not in declaration


@pytest.mark.parametrize("file,name", [
    ("WindowChrome.swift", "WindowEmptyState"),
    ("WindowChrome.swift", "WindowNoticeRow"),
    ("WindowChrome.swift", "WindowStatusCapsule"),
    ("SettingsAtoms.swift", "SettingsBanner"),
    ("SettingsAtoms.swift", "CardNote"),
    ("SettingsView.swift", "SectionNote"),
    ("UsageCenterView.swift", "UsageCenterNoticeView"),
    ("UsageCenterView.swift", "ResetSaveNotice"),
    ("ControlCenterView.swift", "DeckNotice"),
    ("ControlCenterView.swift", "ConflictBanner"),
    ("HistoryView.swift", "AwayBanner"),
    ("LinkedSyncControls.swift", "LinkedDotNote"),
    ("SettingsPagesB.swift", "EventKitAccessNote"),
    ("SettingsSealViews.swift", "SettingsSealNoticeCard"),
    ("Waits/WaitViews.swift", "PaletteWaitNote"),
    ("Overview/OverviewView.swift", "OverviewEmptyState"),
])
def test_notices_use_the_shared_renderer(file, name):
    root = Path(__file__).resolve().parents[1] / "app/Sources/JRBarApp"
    declaration = (root / file).read_text().split("struct " + name, 1)[1].split("\n}\n", 1)[0]
    assert "StatusBanner(" in declaration or "WindowEmptyState(" in declaration


def test_art_glyph_tokens_only_belong_to_their_named_figures():
    from scripts.check_design_tokens import ART_GLYPH_CONTEXTS

    for file, glyphs in ART_GLYPH_CONTEXTS.items():
        for glyph, context in glyphs.items():
            call = f"JRBarTokens.ArtGlyph.{glyph}.font(figure: 18)"
            figure = f"struct {context} {{ var body: some View {{ Text(\"!\").font({call}) }} }}"
            assert not offenders(figure, file)
            assert offenders(figure, "app/Sources/JRBarApp/Unrelated.swift")
            assert offenders(f"struct ReadingLabel {{ var body: some View {{ Text(\"Read\").font({call}) }} }}", file)
    assert offenders("Text(\"!\").font(.system(size: 5.2))", next(iter(ART_GLYPH_CONTEXTS)))
