"""Public facade for JR-Bar's single production AppKit controller.

All controller behavior lives in ``_status_bar_production``. This module keeps
legacy imports, monkeypatches and source introspection compatible without
defining or rebinding another Objective-C subclass. Small module-level
adapters provide stable device identity without adding business logic to the
retained controller. The adapters are installed only by
``jrbar.application_composition``.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path
from types import ModuleType

from . import _status_bar_production as _production
from .device_identity import DeviceKind, device_kind
from .device_inventory import DeviceIdentityCache

_legacy = _production._legacy
JRStatusBarController = _production.JRStatusBarController
StatusBarController = JRStatusBarController

# Keep immutable references on the retained runtime module. importlib.reload()
# reuses this module object while the runtime already points at our wrappers;
# without these sentinels a reload would wrap a wrapper and recurse.
_ORIGINAL_DEVICE_ID_FOR_ROOT = getattr(
    _legacy,
    "_jrbar_original_device_id_for_root",
    _legacy.device_id_for_root,
)
_ORIGINAL_PERSISTABLE_DEVICE_IDENTITY = getattr(
    _legacy,
    "_jrbar_original_persistable_device_identity",
    _legacy.persistable_device_identity,
)
_DEVICE_IDENTITIES = None
_FACADE_INSTALLED = False
_LAST_DEVICE_REFRESH_REQUEST = float(
    getattr(_legacy, "_jrbar_last_device_refresh_request", 0.0) or 0.0
)


def _device_identity_cache() -> DeviceIdentityCache:
    global _DEVICE_IDENTITIES
    if type(_DEVICE_IDENTITIES) is DeviceIdentityCache:
        return _DEVICE_IDENTITIES
    retained = getattr(_legacy, "_jrbar_device_identity_cache", None)
    _DEVICE_IDENTITIES = (
        retained if type(retained) is DeviceIdentityCache else DeviceIdentityCache()
    )
    return _DEVICE_IDENTITIES


def _request_device_identity_refresh(now: float | None = None) -> None:
    global _LAST_DEVICE_REFRESH_REQUEST
    reference = time.monotonic() if now is None else float(now)
    # One disk-info fork per mount each time; a minute between
    # refreshes is plenty for a strip that mounts once and stays.
    if reference - _LAST_DEVICE_REFRESH_REQUEST < 60.0:
        return
    _LAST_DEVICE_REFRESH_REQUEST = reference
    _legacy._jrbar_last_device_refresh_request = reference
    _device_identity_cache().request_refresh()


def device_id_for_root(root: Path) -> str:
    """Return the stable cached hardware key without blocking AppKit."""
    _request_device_identity_refresh()
    identity = _device_identity_cache().identity_for_mount(Path(root))
    return identity.key if identity is not None else _ORIGINAL_DEVICE_ID_FOR_ROOT(root)


def persistable_device_identity(device_id: str, path: str) -> bool:
    """Reject path ghosts once stable inventory owns that physical device."""
    if device_id == _legacy.VIRTUAL_DEVICE_ID or path == _legacy.VIRTUAL_DEVICE_ID:
        return True
    snapshot = _device_identity_cache().snapshot()
    if isinstance(device_id, str) and device_id.startswith("sidepulse:"):
        # A stable-keyed entry whose mount is now owned by a DIFFERENT
        # stable key is a ghost of a re-keyed device (e.g. a Pro that
        # was remembered as a Dot before STATUS.TXT serials corrected
        # the classification) -- keep the live key, drop the ghost.
        return not any(
            identity.mount_path == path and identity.key != device_id
            for identity in snapshot
        )
    if not snapshot:
        return _ORIGINAL_PERSISTABLE_DEVICE_IDENTITY(device_id, path)
    if any(identity.mount_path == path for identity in snapshot):
        return False
    kind = device_kind(Path(path).name, path)
    if kind is not DeviceKind.UNKNOWN and any(
        identity.kind is kind for identity in snapshot
    ):
        return False
    return _ORIGINAL_PERSISTABLE_DEVICE_IDENTITY(device_id, path)


def install_status_bar_facade():
    """Install the device adapters after production composition."""
    global _FACADE_INSTALLED
    if _FACADE_INSTALLED and _legacy.StatusBarController is JRStatusBarController:
        return JRStatusBarController
    _production.install_status_bar_production()
    _legacy._jrbar_original_device_id_for_root = _ORIGINAL_DEVICE_ID_FOR_ROOT
    _legacy._jrbar_original_persistable_device_identity = (
        _ORIGINAL_PERSISTABLE_DEVICE_IDENTITY
    )
    cache = _device_identity_cache()
    _legacy._jrbar_device_identity_cache = cache
    _legacy.device_id_for_root = device_id_for_root
    _legacy.persistable_device_identity = persistable_device_identity
    _legacy.StatusBarController = JRStatusBarController
    _FACADE_INSTALLED = True
    return JRStatusBarController


class _StatusBarFacade(ModuleType):
    """Forward reads and monkeypatches to the retained runtime module."""

    def __getattr__(self, name: str):
        if hasattr(_production, name):
            return getattr(_production, name)
        return getattr(_legacy, name)

    def __setattr__(self, name: str, value) -> None:
        if name in {
            "__all__",
            "__class__",
            "__doc__",
            "__file__",
            "__loader__",
            "__name__",
            "__package__",
            "__path__",
            "__spec__",
        } or name.startswith("_facade_"):
            super().__setattr__(name, value)
            return
        setattr(_legacy, name, value)
        super().__setattr__(name, value)

    def __delattr__(self, name: str) -> None:
        if name in {"__all__", "__class__"} or name.startswith("_facade_"):
            super().__delattr__(name)
            return
        if hasattr(_legacy, name):
            delattr(_legacy, name)
        if name in self.__dict__:
            super().__delattr__(name)

    def __dir__(self) -> list[str]:
        return sorted(
            set(super().__dir__()) | set(dir(_production)) | set(dir(_legacy))
        )


__all__ = tuple(
    sorted(
        {name for name in dir(_legacy) if not name.startswith("_")}
        | {
            "JRStatusBarController",
            "StatusBarController",
            "device_id_for_root",
            "install_status_bar_facade",
            "persistable_device_identity",
        }
    )
)
_facade_module = sys.modules[__name__]
_facade_module.__class__ = _StatusBarFacade
_facade_module.__file__ = _legacy.__file__
