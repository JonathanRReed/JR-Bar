"""Import-compat shim: ``sidepulse.*`` resolves to ``jrbar.*`` for one release.

Hook commands registered before the JR-Bar rename still run
``python -m sidepulse.hook_client``. Importing this package installs a
``sys.meta_path`` finder that maps any ``sidepulse.<name>`` import onto the
already-loaded ``jrbar.<name>`` module object, so both names share one module
(``sidepulse.hook_client is jrbar.hook_client``). The three sibling files in
this directory are plain forwarders so ``python -m`` keeps a real code object
to run. Nothing else lives here; new code imports ``jrbar`` directly.
"""

from __future__ import annotations

import importlib
import importlib.abc
import importlib.util
import sys
from types import ModuleType

_OLD_ROOT = "sidepulse"
_NEW_ROOT = "jrbar"


class _AliasLoader(importlib.abc.Loader):
    def __init__(self, target: str) -> None:
        self._target = target

    def create_module(self, spec: object) -> ModuleType:
        return importlib.import_module(self._target)

    def exec_module(self, module: ModuleType) -> None:  # pragma: no cover - trivial
        return None


class _AliasFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname: str, path: object = None, target: object = None):  # type: ignore[override]
        if not fullname.startswith(_OLD_ROOT + "."):
            return None
        target_name = _NEW_ROOT + fullname[len(_OLD_ROOT):]
        try:
            target_spec = importlib.util.find_spec(target_name)
        except (ImportError, ValueError):
            return None
        if target_spec is None:
            return None
        return importlib.util.spec_from_loader(
            fullname,
            _AliasLoader(target_name),
            origin=target_spec.origin,
            is_package=target_spec.submodule_search_locations is not None,
        )


def _install() -> None:
    if not any(isinstance(finder, _AliasFinder) for finder in sys.meta_path):
        # Appended, not prepended: the forwarder files in this directory win
        # for the names they cover, the alias handles everything else.
        sys.meta_path.append(_AliasFinder())


_install()


def __getattr__(name: str) -> object:
    if name.startswith("_"):
        raise AttributeError(name)
    return getattr(importlib.import_module(_NEW_ROOT), name)
