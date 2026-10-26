import json

from jrbar.colors import ColorSettings
from jrbar.core_runtime import get_path, set_path
from jrbar.settings import AgentMonitorSettings, load_settings, save_settings


def test_only_blend_mode_is_stored_and_stale_alias_is_removed(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"colors": {"blend_mode": "cycle", "mix_mode": "weave", "future_field": 7}}))
    settings = load_settings(path)
    assert settings.colors.blend_mode == "cycle"
    save_settings(settings, path)
    saved = json.loads(path.read_text())["colors"]
    assert saved["blend_mode"] == "cycle"
    assert "mix_mode" not in saved
    assert saved["future_field"] == 7
    assert ColorSettings.from_dict({"mix_mode": "tide"}).blend_mode == "tide"


def test_old_daemon_save_cannot_resurrect_a_stale_mix_choice(tmp_path):
    path = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(colors=ColorSettings.defaults().with_blend_mode("weave")), path)
    document = json.loads(path.read_text())
    # The old daemon preserves unknown fields, then overlays its encoded
    # fields. Changing its existing blend key must be the final choice.
    document["colors"] = {**document["colors"], "blend_mode": "round_robin"}
    path.write_text(json.dumps(document))
    settings = load_settings(path)
    assert settings.colors.blend_mode == "round_robin"
    save_settings(settings.with_colors(settings.colors.with_blend_mode("tide")), path)
    saved = json.loads(path.read_text())
    assert saved["colors"]["blend_mode"] == "tide"
    assert "mix_mode" not in saved["colors"]
    # Another old save after that new save still wins.
    saved["colors"]["blend_mode"] = "spatial_split"
    path.write_text(json.dumps(saved))
    assert load_settings(path).colors.blend_mode == "spatial_split"


def test_protocol_alias_reads_and_writes_the_canonical_key():
    document = {"colors": ColorSettings.defaults().to_dict()}
    assert set_path(document, "colors.mix_mode", "alternate")
    assert get_path(document, "colors.mix_mode") == ("alternate", True)
    assert get_path(document, "colors.blend_mode") == ("alternate", True)
    assert "mix_mode" not in document["colors"]


def test_protocol_publishes_the_alias_without_mutating_the_saved_document():
    from jrbar.core_projection import build_settings_document

    stored = {"colors": ColorSettings.defaults().with_blend_mode("tide").to_dict()}
    published = build_settings_document(stored, generation=1)["document"]["colors"]
    assert published["mix_mode"] == published["blend_mode"] == "tide"
    assert "mix_mode" not in stored["colors"]


def test_old_spotlight_keeps_provider_turns_and_new_relay_survives_save(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"colors": {"blend_mode": "relay"},
        "devices": [{"id": "synthetic:strip", "blend_mode": "relay"}]}))
    migrated = load_settings(path)
    assert migrated.colors.mix_mode == "cycle"
    assert migrated.device_blend_mode("synthetic:strip") == "cycle"
    save_settings(migrated, path)
    assert json.loads(path.read_text())["colors"]["mix_schema_version"] == 1
    chosen = migrated.with_colors(migrated.colors.with_blend_mode("relay"))
    chosen = chosen.with_device_blend_mode("synthetic:strip", "relay")
    save_settings(chosen, path)
    restored = load_settings(path)
    assert restored.colors.mix_mode == "relay"
    assert restored.device_blend_mode("synthetic:strip") == "relay"
    assert ColorSettings.from_dict({"mix_mode": "relay"}).mix_mode == "cycle"
