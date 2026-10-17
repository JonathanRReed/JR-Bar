"""A late Deck save must not complete the next command's wait."""

import pytest

from jrbar import creator_micro_settings
from jrbar.core_server import CommandError
from jrbar.creator_micro_settings import CreatorMicroSettingsResult
from tests.test_core_runtime import headless  # noqa: F401


def test_timed_out_save_cannot_supply_the_next_disable_receipt(headless, monkeypatch):  # noqa: F811
    results = []

    def save(target, enabled):
        generation = object()
        target._creator_micro_settings_generation = generation
        results.append(CreatorMicroSettingsResult(
            generation, enabled, len(results) == 0, "saved" if not results else "settings_save_failed",
        ))

    class Completion:
        ready = False

        def clear(self):
            self.ready = False

        def set(self):
            self.ready = True

        def wait(self, timeout):
            if len(results) == 1:
                return False
            headless.applyCreatorMicroSettings_(results[0])
            if self.ready:
                return True
            headless.applyCreatorMicroSettings_(results[1])
            return self.ready

    monkeypatch.setattr(creator_micro_settings, "save_creator_micro_choice_async", save)
    headless._core_deck_settings_done = Completion()
    with pytest.raises(CommandError, match="did not finish in time"):
        headless._core_dispatch("deck_disable", {})
    with pytest.raises(CommandError) as failure:
        headless._core_dispatch("deck_disable", {})
    assert failure.value.code == "refused"
    assert headless._core_deck_settings_result is results[1]


def test_superseded_or_stopping_result_does_not_publish_completion(headless):  # noqa: F811
    current = object()
    headless._creator_micro_settings_generation = current
    headless._core_deck_settings_done.clear()
    headless._core_deck_settings_result = None
    stale = CreatorMicroSettingsResult(object(), False, True, "saved")
    headless.applyCreatorMicroSettings_(stale)
    assert not headless._core_deck_settings_done.is_set()
    assert headless._core_deck_settings_result is None
    headless._runtime_termination_started = True
    headless.applyCreatorMicroSettings_(CreatorMicroSettingsResult(current, False, True, "saved"))
    assert not headless._core_deck_settings_done.is_set()
    assert headless._core_deck_settings_result is None
