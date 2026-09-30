"""The OpenCode plugin file: its generations, and what the bridge tells the daemon.

JR-Bar proves it owns an installed plugin by comparing the file with the exact
text of the generation its marker names. Editing the template therefore
strands every installed file unless the older generation stays recognised, so
the file is versioned: v2 is the current template, v1 is frozen, and an install
of either is detected, replaced by v2 and removed like any other. Nothing here
runs an install against a real ``~/.config/opencode``: every test takes a
temporary home.
"""

from __future__ import annotations

import json
import stat
import sys
from pathlib import Path

import pytest

from jrbar.install import (
    install_opencode_plugin,
    opencode_plugin_source,
    uninstall_opencode_plugin,
)
from jrbar.providers import (
    OPENCODE_EVENTS,
    OPENCODE_PLUGIN_MARKER,
    _opencode_plugin_v1_source_for_arguments,
    default_opencode_plugin_path,
    detect_opencode_plugin,
    legacy_opencode_plugin_source_for_arguments,
    managed_opencode_plugin_log_path,
    opencode_plugin_source_for_arguments,
)

_FIXTURES = Path(__file__).parent / "fixtures" / "opencode"
_V1_MARKER = "jrbar-opencode-plugin-v1"


def _arguments(log: Path) -> list[str]:
    """The exact argv the installer registers, with a synthetic log path."""
    return [sys.executable, "-m", "jrbar.hook_client", "--provider", "opencode", "--log", str(log)]


def _v1(log: Path) -> str:
    return _opencode_plugin_v1_source_for_arguments(_arguments(log))


@pytest.fixture
def home(tmp_path: Path) -> Path:
    plugin = default_opencode_plugin_path(tmp_path)
    plugin.parent.mkdir(parents=True)
    return tmp_path


# --- the generations ---------------------------------------------------------


def test_the_current_template_carries_the_v2_marker() -> None:
    assert OPENCODE_PLUGIN_MARKER == "jrbar-opencode-plugin-v2"
    source = opencode_plugin_source_for_arguments(_arguments(Path("/synthetic/opencode.jsonl")))
    assert source.startswith(f"// {OPENCODE_PLUGIN_MARKER}\nconst JRBAR_HOOK_ARGS = Object.freeze(")


def test_the_frozen_v1_generator_equals_the_checked_in_copy() -> None:
    """A later template edit cannot silently redefine what v1 means."""
    arguments = _arguments(Path("/synthetic/state/opencode.jsonl"))
    literal = (_FIXTURES / "plugin-v1.js.template").read_text(encoding="utf-8")
    expected = literal.replace("__HOOK_ARGS__", json.dumps(arguments, separators=(",", ":")))

    assert _opencode_plugin_v1_source_for_arguments(arguments) == expected
    assert expected.startswith(f"// {_V1_MARKER}\n")


def test_the_v1_and_v2_bodies_differ_so_an_install_can_be_told_apart() -> None:
    log = Path("/synthetic/opencode.jsonl")
    assert _v1(log) != opencode_plugin_source(log, python_executable=sys.executable)


def test_the_pre_rename_generator_derives_from_the_frozen_v1_body() -> None:
    arguments = _arguments(Path("/synthetic/old-state/opencode.jsonl"))
    legacy = legacy_opencode_plugin_source_for_arguments(arguments)
    expected = (
        _opencode_plugin_v1_source_for_arguments(arguments)
        .replace(f"// {_V1_MARKER}\n", "// sidepulse-opencode-plugin-v1\n", 1)
        .replace("JRBAR_", "SIDEPULSE_")
        .replace("JRBarPlugin", "SidePulsePlugin")
    )

    assert legacy == expected
    assert legacy.startswith("// sidepulse-opencode-plugin-v1\nconst SIDEPULSE_HOOK_ARGS = Object.freeze(")
    assert "JRBAR" not in legacy and "JRBar" not in legacy
    assert managed_opencode_plugin_log_path(legacy) == Path("/synthetic/old-state/opencode.jsonl")


# --- an install of the frozen v1 generation keeps working --------------------


def test_a_v1_plugin_is_still_detected_as_installed(home: Path) -> None:
    log = home / ".local" / "state" / "jrbar" / "opencode.jsonl"
    default_opencode_plugin_path(home).write_text(_v1(log))

    detected = detect_opencode_plugin(home)

    assert detected.exists and detected.hooks_enabled
    assert detected.hook_events == OPENCODE_EVENTS
    assert detected.log_paths == (log,)
    assert managed_opencode_plugin_log_path(_v1(log)) == log


def test_installing_over_v1_leaves_exactly_the_v2_source(home: Path) -> None:
    plugin = default_opencode_plugin_path(home)
    log = home / "state" / "opencode.jsonl"
    plugin.write_text(_v1(log))

    first = install_opencode_plugin(log, plugin_path=plugin, python_executable=sys.executable)

    assert first.changed
    assert plugin.read_text() == opencode_plugin_source(log, python_executable=sys.executable)
    assert plugin.read_text().startswith(f"// {OPENCODE_PLUGIN_MARKER}\n")
    assert stat.S_IMODE(plugin.stat().st_mode) == 0o600
    assert detect_opencode_plugin(home).log_paths == (log,)

    second = install_opencode_plugin(log, plugin_path=plugin, python_executable=sys.executable)

    assert not second.changed


def test_uninstall_removes_either_generation(home: Path) -> None:
    plugin = default_opencode_plugin_path(home)
    log = home / "state" / "opencode.jsonl"
    plugin.write_text(_v1(log))

    removed_v1 = uninstall_opencode_plugin(log, plugin_path=plugin)

    assert removed_v1.changed and not plugin.exists()

    plugin.write_text(opencode_plugin_source(log, python_executable=sys.executable))
    removed_v2 = uninstall_opencode_plugin(log, plugin_path=plugin)

    assert removed_v2.changed and not plugin.exists()


def test_a_v1_file_with_one_edited_byte_is_refused_as_unowned(home: Path) -> None:
    plugin = default_opencode_plugin_path(home)
    log = home / "state" / "opencode.jsonl"
    edited = _v1(log) + "// arbitrary edit\n"
    plugin.write_text(edited)

    assert not detect_opencode_plugin(home).exists
    assert managed_opencode_plugin_log_path(edited) is None
    with pytest.raises(OSError):
        install_opencode_plugin(log, plugin_path=plugin, python_executable=sys.executable)
    with pytest.raises(OSError):
        uninstall_opencode_plugin(log, plugin_path=plugin)
    assert plugin.read_text() == edited


def test_a_v1_file_with_forged_arguments_is_refused(home: Path) -> None:
    plugin = default_opencode_plugin_path(home)
    log = home / "state" / "opencode.jsonl"
    source = _v1(log)
    forged_variants = (
        source.replace(sys.executable, "/tmp/forged-executable", 1),
        source.replace(
            "const JRBAR_HOOK_ARGS = Object.freeze([",
            'const JRBAR_HOOK_ARGS = Object.freeze(["/tmp/forged-prefix",',
            1,
        ),
    )

    for forged in forged_variants:
        plugin.write_text(forged)
        assert not detect_opencode_plugin(home).exists
        with pytest.raises(OSError):
            install_opencode_plugin(log, plugin_path=plugin, python_executable=sys.executable)
        with pytest.raises(OSError):
            uninstall_opencode_plugin(log, plugin_path=plugin)


def test_a_pre_rename_stub_still_reads_as_not_installed(home: Path) -> None:
    default_opencode_plugin_path(home).write_text(
        "// sidepulse-opencode-plugin-v1\nconst SIDEPULSE_HOOK_ARGS = Object.freeze([]);\n"
    )

    assert not detect_opencode_plugin(home).exists

