from __future__ import annotations

from collections.abc import Iterator
from itertools import count

import pytest

from jrbar.dnd_policy import DndMode, DndSource
from jrbar.settings import AgentMonitorSettings
from tests.test_dnd_controller import _active_focus, _FocusClient, _Harness


@pytest.mark.parametrize("count", [17, 64])
def test_complete_named_focus_detail_reaches_dnd(count: int) -> None:
    identifiers = tuple(f"synthetic.mode.{i:02}" for i in range(count))
    settings = (
        AgentMonitorSettings().with_focus_sync_enabled(True)
        .with_dnd_focus_mode(DndMode.DIM)
        .with_focus_dim_rule(identifiers[-1], 0.08)
    )
    harness = _Harness(settings, focus=_FocusClient(_active_focus()), named_reader=lambda: identifiers)
    harness.controller.start()
    assert harness.controller.named_focus_identifiers == identifiers
    assert DndSource.NAMED_FOCUS in harness.controller.projection.active_sources
    assert harness.controller.projection.brightness_factor == pytest.approx(0.08)


@pytest.mark.parametrize("identifier", [" synthetic.work ", "é" * 128])
def test_named_focus_identifiers_keep_exact_identity(identifier: str) -> None:
    harness = _Harness(
        AgentMonitorSettings().with_focus_sync_enabled(True),
        focus=_FocusClient(_active_focus()), named_reader=lambda: [identifier],
    )
    harness.controller.start()
    assert harness.controller.named_focus_identifiers == (identifier,)


@pytest.mark.parametrize("invalid", [7, "", " \t", "é" * 129, "\ud800"])
def test_malformed_named_focus_detail_does_not_publish_a_partial_set(invalid: object) -> None:
    harness = _Harness(
        AgentMonitorSettings().with_focus_sync_enabled(True),
        focus=_FocusClient(_active_focus()), named_reader=lambda: ["synthetic.work", invalid],
    )
    harness.controller.start()
    assert harness.controller.named_focus_identifiers == ()
    assert DndSource.NAMED_FOCUS not in harness.controller.projection.active_sources
    assert harness.controller.focus_observation == _active_focus()


def test_injected_named_focus_uses_the_same_complete_contract() -> None:
    identifiers = tuple(f"synthetic.mode.{i:02}" for i in range(64))
    harness = _Harness(AgentMonitorSettings().with_focus_sync_enabled(True))
    harness.controller.start()
    assert harness.controller._accept_focus_observation(
        harness.controller._generation, _active_focus(), identifiers,
    )
    assert harness.controller.named_focus_identifiers == identifiers
    assert harness.controller._accept_focus_observation(
        harness.controller._generation, _active_focus(), ["synthetic.work", 7],
    )
    assert harness.controller.named_focus_identifiers == ()
    assert harness.controller.focus_observation == _active_focus()


@pytest.mark.parametrize("duplicates", [False, True])
def test_named_focus_reader_rejects_65_raw_entries(duplicates: bool) -> None:
    identifiers = tuple(
        "synthetic.work" if duplicates else f"synthetic.mode.{i:02}"
        for i in range(65)
    )
    harness = _Harness(
        AgentMonitorSettings().with_focus_sync_enabled(True),
        focus=_FocusClient(_active_focus()), named_reader=lambda: identifiers,
    )
    harness.controller.start()
    assert harness.controller.named_focus_identifiers == ()
    assert DndSource.NAMED_FOCUS not in harness.controller.projection.active_sources
    assert harness.controller.focus_observation == _active_focus()


def test_named_focus_reader_bounds_an_endless_duplicate_stream() -> None:
    consumed: list[int] = []

    def identifiers() -> Iterator[str]:
        for index in count():
            consumed.append(index)
            assert index < 65, "Reader requested a 66th entry"
            yield "synthetic.work"

    harness = _Harness(
        AgentMonitorSettings().with_focus_sync_enabled(True),
        focus=_FocusClient(_active_focus()), named_reader=identifiers,
    )
    harness.controller.start()
    assert consumed == list(range(65))
    assert harness.controller.named_focus_identifiers == ()
    assert DndSource.NAMED_FOCUS not in harness.controller.projection.active_sources
    assert harness.controller.focus_observation == _active_focus()
