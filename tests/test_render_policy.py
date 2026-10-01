from __future__ import annotations

from jrbar.render_policy import runtime_render_environment


def test_runtime_environment_reads_public_power_state_with_fallbacks() -> None:
    class ProcessInfo:
        @staticmethod
        def isLowPowerModeEnabled() -> bool:
            return True

        @staticmethod
        def thermalState() -> int:
            return 2

    environment = runtime_render_environment(
        visible=True,
        display_asleep=False,
        process_info=ProcessInfo(),
    )
    fallback = runtime_render_environment(
        visible=True,
        process_info=object(),
    )

    assert environment.low_power is True
    assert environment.thermal == "serious"
    assert fallback.low_power is False
    assert fallback.thermal == "nominal"
