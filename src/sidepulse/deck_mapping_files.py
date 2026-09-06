"""Explicit, bounded import/export of user-selected data-only control mappings."""
from __future__ import annotations

import json
import os
import stat
import threading
from dataclasses import dataclass, replace
from pathlib import Path

from .deck_control_settings import DeckControlSettings, decode_deck_controls
from .private_io import atomic_private_write


@dataclass(frozen=True, slots=True)
class DeckFileResult:
    generation: object
    operation: str
    previous: DeckControlSettings
    candidate: DeckControlSettings | None = None
    error: str | None = None


def _read_selected(path: Path) -> str:
    """The picker grants access to this one regular, owned file, not a directory scan."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_size > 32 * 1024:
            raise ValueError("Choose an owned JSON file of at most 32 KiB.")
        raw = bytearray()
        while len(raw) <= 32 * 1024:
            chunk = os.read(fd, min(8192, 32 * 1024 + 1 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        after = os.fstat(fd)
        if (len(raw) > 32 * 1024 or (before.st_size, before.st_mtime_ns, before.st_ino) !=
                (after.st_size, after.st_mtime_ns, after.st_ino)):
            raise ValueError("The selected file changed while reading it.")
        return raw.decode("utf-8")
    finally:
        os.close(fd)


def choose_mapping_file(target, operation: str) -> None:
    from AppKit import NSModalResponseOK, NSOpenPanel, NSSavePanel
    previous = getattr(target, "_deck_control_settings", None)
    if type(previous) is not DeckControlSettings or operation not in {"import", "export", "backup"}:
        return
    if operation == "import":
        panel = NSOpenPanel.openPanel()
        panel.setCanChooseDirectories_(False)
        panel.setAllowsMultipleSelection_(False)
        panel.setAllowedFileTypes_(["json"])
    else:
        panel = NSSavePanel.savePanel()
        panel.setNameFieldStringValue_("creator-micro-original-keymap.json" if operation == "backup" else "jrbar-controls.json")
    if panel.runModal() != NSModalResponseOK or panel.URL() is None:
        return
    path = Path(str(panel.URL().path()))
    generation = object()
    target._deck_file_generation = generation

    def worker() -> None:
        try:
            candidate = None
            if operation == "import":
                candidate = replace(decode_deck_controls(_read_selected(path)), enabled=False)
            elif operation == "export":
                atomic_private_write(path, json.dumps(previous.to_dict(), indent=2) + "\n")
            else:
                from .creator_micro_setup import CreatorMicroSetup
                from .creator_micro_setup_controller import _backup_path
                from .integration_settings import load_integration_settings
                settings = load_integration_settings().settings
                serial = settings.creator_micro_device_serial
                setup = CreatorMicroSetup(None, serial, _backup_path(serial, None))
                backup = setup._load_backup()
                atomic_private_write(path, backup["original_json"])
            result = DeckFileResult(generation, operation, previous, candidate)
        except Exception:
            result = DeckFileResult(generation, operation, previous,
                                   error="The selected file or private backup could not be processed safely. No mapping was applied.")
        if not getattr(target, "_runtime_termination_started", False):
            target.performSelectorOnMainThread_withObject_waitUntilDone_("applyDeckFileResult:", result, False)

    threading.Thread(target=worker, name="JRBarDeckMappingFile", daemon=True).start()


def apply_mapping_file_result(target, result) -> None:
    from AppKit import NSAlert, NSAlertFirstButtonReturn

    from .deck_settings_controller import _submit_save
    from .deck_settings_pane import _mapping_summary
    if (type(result) is not DeckFileResult or result.generation is not getattr(target, "_deck_file_generation", None)
            or getattr(target, "_runtime_termination_started", False)):
        return
    pane = getattr(target, "deck_settings_pane", None)
    if pane is None:
        return
    if result.error:
        pane.set_status(result.error)
        return
    if result.operation != "import":
        pane.set_status("Exported privately to the selected file.")
        return
    if result.previous != getattr(target, "_deck_control_settings", None):
        pane.set_status("Mappings changed while importing. Choose the file again.")
        return
    candidate = result.candidate
    alert = NSAlert.alloc().init()
    alert.setMessageText_("Replace the saved control mappings?")
    summary = "\n".join(_mapping_summary(key, action) for key, action in candidate.bindings) or "No mappings."
    alert.setInformativeText_(summary + "\n\nImported actions stay disabled. Review names and app targets, "
                             "then explicitly enable device actions. System Shortcuts may execute user automation.")
    alert.addButtonWithTitle_("Import disabled mappings")
    alert.addButtonWithTitle_("Cancel")
    if alert.runModal() == NSAlertFirstButtonReturn:
        runtime = getattr(target, "_sidepulse_optional_integration_runtime", None)
        if runtime is not None:
            runtime.revoke_deck_input()
        _submit_save(target, candidate, result.previous)
