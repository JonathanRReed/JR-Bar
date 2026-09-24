"""Every click must do something.

The dropdown walk that lived here went with the retired menu bar. What is
left: the Screen Bar sampler's batched engine call, and the hook buttons
Settings and Setup build for every provider.
"""

from __future__ import annotations

from types import SimpleNamespace

from test_jrbar import isolate_controller


def test_sampler_serves_frames_from_one_batched_engine_call() -> None:
    """Wave 1: the bar's sampler must amortize JavaScriptCore round-trips
    by prefetching frame batches, with byte-identical output."""
    from jrbar.led_wasm import LedWasmUnavailableError, SdLedWasmController
    from jrbar.screen_bar_pipeline import ScreenBarSampler, TwoSampleBuffer

    try:
        raw = SdLedWasmController(led_count=8)
    except LedWasmUnavailableError:
        import pytest

        pytest.skip("JavaScriptCore unavailable")

    calls = {"step": 0, "batch": 0}

    class Counting:
        def parse(self, program, now_ms):
            return raw.parse(program, now_ms)

        def step(self, now_ms):
            calls["step"] += 1
            return raw.step(now_ms)

        def step_batch(self, start_ms, interval_ms, frames):
            calls["batch"] += 1
            return raw.step_batch(start_ms, interval_ms, frames)

    sampler = ScreenBarSampler(
        TwoSampleBuffer(), controller_factory=Counting, led_count=8
    )
    program = (
        "0:#6C3C2C 1600ms pulse 0ms; 1:#47474A 1600ms pulse 192ms; "
        "2:#6C3C2C 1600ms pulse 384ms; 3:#47474A 1600ms pulse 576ms; "
        "4:#6C3C2C 1600ms pulse 768ms; 5:#47474A 1600ms pulse 960ms; "
        "6:#6C3C2C 1600ms pulse 1152ms; 7:#47474A 1600ms pulse 1344ms\n"
        "repeat"
    )
    assert raw.parse(program, 1000).ok
    # The production cadence: GENTLE_MOTION_FPS accumulates a FLOAT
    # interval (1/30s), while batch stamps once stepped by the rounded
    # integer millisecond interval -- a ~1/3ms-per-frame drift that blew
    # the +/-1ms gate and silently discarded most of every batch.
    interval = 1.0 / 30.0
    sampled_at = 1.0
    pixels = sampler._pixels_for(Counting(), sampled_at, interval)
    assert pixels is not None and len(pixels) == 8
    # 23 more frames ride the same engine call.
    for _ in range(1, 24):
        sampled_at += interval
        served = sampler._pixels_for(Counting(), sampled_at, interval)
        assert served is not None
    assert calls["batch"] == 1, "a served batch must not be re-rendered"
    assert calls["step"] == 0
    sampler.close(timeout_seconds=2.0)


def test_every_hook_provider_has_install_and_uninstall_actions(request):
    """Settings and Setup build install/uninstall buttons for EVERY entry
    in HOOK_PROVIDERS via f"install{Provider}Hooks:" -- a provider added
    without its controller IBActions ships dead buttons (opencode,
    antigravity, and kiro did exactly that)."""
    case = SimpleNamespace(
        addCleanup=lambda fn, *a, **k: request.addfinalizer(lambda: fn(*a, **k)),
    )
    isolate_controller(case)
    controller = case.controller

    from jrbar.providers import HOOK_PROVIDERS

    dead: list[str] = []
    for provider in HOOK_PROVIDERS:
        for prefix in ("install", "uninstall"):
            method = f"{prefix}{provider.title()}Hooks_"
            if not callable(getattr(controller, method, None)):
                dead.append(method)
    assert dead == [], f"hook buttons with no action: {dead}"
