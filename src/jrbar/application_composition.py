"""Explicit production composition root for the JR-Bar AppKit application.

This module is deliberately inert on import. The foreground entrypoints call
``compose_status_bar_application`` immediately before the retained runtime
creates its AppKit delegate and enters the event loop.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class ApplicationCompositionReceipt:
    """Stable identity of the controller layers installed at boot."""

    controller: type
    final_controller: type
    steps: tuple[str, ...]


_receipt: ApplicationCompositionReceipt | None = None


def compose_status_bar_application() -> ApplicationCompositionReceipt:
    """Install the complete foreground runtime in one deterministic order."""
    global _receipt

    from . import _status_bar_production as production
    from . import provider_usage_status_bar as provider_host
    from . import status_bar as public_status_bar
    from . import status_bar_legacy as legacy
    from .ambient_effect_runtime import install_ambient_effect_runtime

    if _receipt is not None and legacy.StatusBarController is _receipt.final_controller:
        return _receipt

    production_controller = production.install_status_bar_production()
    controller = public_status_bar.install_status_bar_facade()
    install_ambient_effect_runtime(controller)
    final_controller = provider_host.install_provider_usage_status_bar()

    if controller is not production_controller:
        raise RuntimeError("status-bar production controller composition drifted")

    _receipt = ApplicationCompositionReceipt(
        controller=controller,
        final_controller=final_controller,
        steps=(
            "production-controller",
            "status-bar-facade",
            "ambient-effects-runtime",
            "provider-usage-controller",
        ),
    )
    return _receipt


__all__ = [
    "ApplicationCompositionReceipt",
    "compose_status_bar_application",
]
