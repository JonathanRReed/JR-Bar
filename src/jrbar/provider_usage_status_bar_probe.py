"""Probe-only helpers for provider_usage_status_bar import-time contracts."""

from __future__ import annotations

import os
import sys

# A test's `python -c` probe subprocess, which inherits PYTEST_CURRENT_TEST.
# A pytest-xdist worker is also a `python -c` process under a test, but it
# has pytest itself loaded; that is what tells the two apart.
PROBE_IMPORT_MODE = (
    os.environ.get("PYTEST_CURRENT_TEST") is not None
    and sys.argv[:1] == ["-c"]
    and "_pytest" not in sys.modules
)


class ProbeLegacyShim:
    class objc:
        @staticmethod
        def IBAction(function):
            return function


def probe_build_menu(snapshot, state, target):
    from . import status_bar as host
    from .sparkle_updater import inject_software_update_submenu
    from .usage_menu_injection import (
        menu_index,
        native_usage_menu_item,
        remove_legacy_usage_item,
        remove_redundant_separators,
    )

    menu = host.build_menu(snapshot, state, target)
    remove_legacy_usage_item(menu, target)
    native_item = native_usage_menu_item(target)
    index = menu_index(menu, "Devices")
    if index < 0:
        index = min(4, menu.numberOfItems())
    menu.insertItem_atIndex_(native_item, index)
    if index + 1 < menu.numberOfItems():
        next_item = menu.itemAtIndex_(index + 1)
        if not next_item.isSeparatorItem():
            menu.insertItem_atIndex_(host._legacy.NSMenuItem.separatorItem(), index + 1)
    inject_software_update_submenu(
        menu,
        target,
        getattr(target, "_jrbar_sparkle_updater", None),
    )
    remove_redundant_separators(menu)
    return menu


__all__ = [
    "PROBE_IMPORT_MODE",
    "ProbeLegacyShim",
    "probe_build_menu",
]
