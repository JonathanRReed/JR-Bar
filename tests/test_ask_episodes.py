"""Rapid ask bursts announce once; distinct asks announce on their own."""

from __future__ import annotations

from types import SimpleNamespace

from jrbar.ask_episodes import ASK_BATCH_SECONDS, batched_episode_key


def test_burst_within_window_reuses_the_first_episode__and_1_more() -> None:
    # --- scenario: burst_within_window_reuses_the_first_episode
    controller = SimpleNamespace()
    first = batched_episode_key(controller, "attention:a", 100.0)
    assert first == "attention:a"
    # A DIFFERENT ask lands 1.5s later: merged into the burst.
    assert batched_episode_key(controller, "attention:b", 101.5) == "attention:a"
    # The window is anchored at the burst's first ask, not extended.
    assert (
        batched_episode_key(controller, "attention:c", 100.0 + ASK_BATCH_SECONDS + 0.1)
        == "attention:c"
    )

    # --- scenario: a_pending_ask_keeps_its_own_key_every_tick
    controller = SimpleNamespace()
    assert batched_episode_key(controller, "attention:a", 100.0) == "attention:a"
    assert batched_episode_key(controller, "attention:a", 100.5) == "attention:a"
    assert batched_episode_key(controller, "attention:a", 500.0) == "attention:a"

