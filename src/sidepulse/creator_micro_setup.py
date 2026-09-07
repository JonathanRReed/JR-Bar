"""Explicit keymap setup with a private backup and verified device readback.

Call from the sole device owner, never AppKit's main thread. Inspection performs
RPC reads only. Apply and restore are separate user-confirmed operations.
"""

from __future__ import annotations

import base64
import hashlib
import json
from collections.abc import Callable
from pathlib import Path

from .creator_micro_adapter import Receipt
from .creator_micro_files import CreatorMicroFiles, FileTransferError
from .creator_micro_keymap import KeymapPlan, keymap_digest, plan_keymap
from .private_io import atomic_private_write, read_private_text

SetupError = FileTransferError


def device_backup_key(serial: str) -> str:
    if type(serial) is not str or not serial.strip() or len(serial) > 256 or not serial.isprintable():
        raise ValueError("invalid approved device identity")
    return hashlib.sha256(serial.encode("utf-8")).hexdigest()


class CreatorMicroSetup:
    def __init__(self, adapter, approved_serial: str, backup_path: Path, *, is_current: Callable[[], bool] = lambda: True):
        self.adapter = adapter
        self.device_key = device_backup_key(approved_serial)
        self.backup_path = Path(backup_path)
        self.is_current = is_current
        self.files = CreatorMicroFiles(adapter, is_current=is_current)
        self.recovery_path = self.backup_path.with_suffix(".recovery.json")

    def _rpc(self, method: str, params=None) -> dict:
        value = self.files.rpc(method, params)
        if type(value) is not dict:
            raise SetupError("malformed_report")
        return value

    def _read_keymap(self) -> str:
        raw = self.files.read_bytes().decode("utf-8")
        keymap_digest(raw)
        return raw

    def inspect(self, **selection) -> KeymapPlan:
        before = self._rpc("device.status")
        raw = self._read_keymap()
        after = self._rpc("device.status")
        if any(before.get(field) != after.get(field) for field in ("profile_index", "layer_index", "version")):
            raise SetupError("keymap_changed")
        return plan_keymap(raw, after, **selection)

    def _backup_document(self, plan: KeymapPlan) -> dict:
        return {
            "version": 1, "device_key": self.device_key,
            "original_json": plan.original_json, "proposed_json": plan.proposed_json,
            "original_digest": plan.original_digest, "proposed_digest": plan.proposed_digest,
        }

    def _load_backup(self) -> dict:
        raw = read_private_text(self.backup_path, max_bytes=266_240)
        document = json.loads(raw)
        if (
            type(document) is not dict
            or set(document) != {"version", "device_key", "original_json", "proposed_json",
                                 "original_digest", "proposed_digest"}
            or type(document["version"]) is not int or document["version"] != 1
            or document["device_key"] != self.device_key
            or keymap_digest(document["original_json"]) != document["original_digest"]
            or keymap_digest(document["proposed_json"]) != document["proposed_digest"]
        ):
            raise SetupError("backup_invalid")
        return document

    def _save_backup(self, plan: KeymapPlan) -> None:
        expected = self._backup_document(plan)
        try:
            existing = self._load_backup()
        except FileNotFoundError:
            atomic_private_write(self.backup_path, json.dumps(expected, ensure_ascii=False) + "\n", overwrite=False)
        else:
            # Never replace the first recoverable keymap with a later state.
            if existing != expected:
                journal = self._load_recovery()
                known = {existing["original_digest"], existing["proposed_digest"]}
                if journal is not None and journal["state"] == "verified":
                    known.add(keymap_digest(journal["after_json"]))
                if plan.original_digest not in known:
                    raise SetupError("backup_conflict")
        self._load_backup()  # Validate the first backup without replacing it.

    def _load_recovery(self) -> dict | None:
        try:
            value = json.loads(read_private_text(self.recovery_path, max_bytes=800_000))
        except FileNotFoundError:
            return None
        if (type(value) is not dict or set(value) != {
                "version", "device_key", "backup_digest", "before_base64", "after_json", "state", "max_prefix"}
                or type(value["version"]) is not int or value["version"] != 1 or value["device_key"] != self.device_key
                or value["backup_digest"] != self._load_backup()["original_digest"]
                or value["state"] not in {"pending", "verified"}
                or type(value["max_prefix"]) is not int):
            raise SetupError("recovery_invalid")
        before = value.get("before_base64")
        if type(before) is not str or len(before) > 4 * ((64 * 1024 + 2) // 3):
            raise SetupError("recovery_invalid")
        if len(base64.b64decode(before, validate=True)) > 64 * 1024:
            raise SetupError("recovery_invalid")
        keymap_digest(value["after_json"])
        if not 0 <= value["max_prefix"] <= len(value["after_json"].encode("utf-8")):
            raise SetupError("recovery_invalid")
        return value

    def _write_verified(self, raw: str, digest: str, success_code: str, *, expected_current: bytes, active_position: tuple[int, int] | None = None) -> Receipt:
        if not self.is_current():
            return Receipt("cancelled", "No keymap was written.")
        journal = {
            "version": 1, "device_key": self.device_key,
            "backup_digest": self._load_backup()["original_digest"],
            "before_base64": base64.b64encode(expected_current).decode("ascii"), "after_json": raw, "state": "pending", "max_prefix": 0,
        }
        mutated = False

        def record(prefix: int) -> None:
            nonlocal mutated
            journal["max_prefix"] = prefix
            atomic_private_write(self.recovery_path, json.dumps(journal, ensure_ascii=False) + "\n")
            mutated = True

        def revalidate() -> None:
            try:
                actual = self.files.read_bytes()
            except SetupError as exc:
                if exc.code != "file_not_found" or expected_current != b"":
                    raise
                actual = b""
            if actual != expected_current:
                raise SetupError("keymap_changed")
            if active_position is not None:
                status = self._rpc("device.status")
                if (status.get("profile_index"), status.get("layer_index")) != active_position:
                    raise SetupError("keymap_changed")

        try:
            self.files.verify_write_protocol()
            self.files.replace_bytes("keymap.json", raw.encode("utf-8"), before_chunk=record, before_replace=revalidate)
            if keymap_digest(self._read_keymap()) != digest:
                raise SetupError("readback_mismatch")
            journal["state"] = "verified"
            atomic_private_write(self.recovery_path, json.dumps(journal, ensure_ascii=False) + "\n")
        except (ValueError, OSError) as exc:
            code = "recovery_required" if mutated else getattr(exc, "code", "readback_failed")
            return Receipt(code, "Private backup retained. Use Restore device keymap; do not repeat Apply.")
        return Receipt(success_code, "Stored bytes verified. Reconnect if the firmware has not activated the new map.")

    def apply(self, plan: KeymapPlan) -> Receipt:
        if not self.is_current():
            return Receipt("cancelled", "No keymap was written.")
        if type(plan) is not KeymapPlan:
            return Receipt("invalid_plan")
        try:
            recovery = self._load_recovery()
            if recovery is not None and recovery["state"] == "pending":
                return Receipt("recovery_required", "Restore the device keymap before applying another change.")
            # Recompute the reviewed transformation so a forged/stale plan
            # cannot write arbitrary JSON through the setup confirmation.
            expected = plan_keymap(plan.original_json, {"layer_index": plan.observed_layer + 1, "profile_index": plan.observed_profile},
                                   profile_index=plan.profile_index, layer_index=plan.layer_index,
                                   include_auxiliary=plan.include_auxiliary)
            if expected != plan:
                return Receipt("invalid_plan")
            current = self.inspect(profile_index=plan.profile_index, layer_index=plan.layer_index,
                                   include_auxiliary=plan.include_auxiliary)
            if (current.original_digest, current.observed_profile, current.observed_layer) != (
                plan.original_digest, plan.observed_profile, plan.observed_layer,
            ):
                return Receipt("keymap_changed")
        except SetupError as exc:
            return Receipt(exc.code)
        except (ValueError, OSError):
            return Receipt("keymap_changed")
        if not plan.changes:
            return Receipt("already_configured")
        try:
            self._save_backup(plan)
        except (ValueError, OSError):
            return Receipt("backup_failed", "No keymap was written.")
        return self._write_verified(plan.proposed_json, plan.proposed_digest, "keymap_verified",
                                    expected_current=plan.original_json.encode("utf-8"),
                                    active_position=(plan.observed_profile, plan.observed_layer + 1))

    def restore(self) -> Receipt:
        if not self.is_current():
            return Receipt("cancelled", "No keymap was written.")
        try:
            backup = self._load_backup()
        except (ValueError, OSError):
            return Receipt("backup_invalid", "No keymap was written.")
        try:
            journal = self._load_recovery()
            try:
                current_raw = self.files.read_bytes()
            except SetupError as exc:
                if journal is None or journal["state"] != "pending" or exc.code not in {
                        "file_not_found", "unsupported_file_protocol"}:
                    raise
                # A missing file is recoverable only with a durable pending operation.
                entries = self.files.rpc("fs.list", {"checksum": True})
                if type(entries) is not list or len(entries) > 256 or any(
                        isinstance(entry, dict) and entry.get("name") == "keymap.json" for entry in entries):
                    raise SetupError("recovery_invalid")
                current_raw = b""
            original = backup["original_json"].encode("utf-8")
            if current_raw == original:
                if journal is not None and journal["state"] == "pending":
                    # A failed transfer may leave the original untouched. Close
                    # the recovery record without issuing a device write.
                    journal.update(state="verified", after_json=backup["original_json"],
                                   max_prefix=len(original), before_base64=base64.b64encode(original).decode("ascii"))
                    atomic_private_write(self.recovery_path, json.dumps(journal, ensure_ascii=False) + "\n")
                return Receipt("already_restored")
            allowed = current_raw == backup["proposed_json"].encode("utf-8")
            if journal is not None:
                intended = journal["after_json"].encode("utf-8")
                allowed = allowed or current_raw == intended
                if journal["state"] == "pending":
                    allowed = allowed or (
                        len(current_raw) <= journal["max_prefix"] and intended.startswith(current_raw)
                    ) or current_raw == base64.b64decode(journal["before_base64"], validate=True)
            if not allowed:
                return Receipt("keymap_changed", "Refusing to overwrite later device edits.")
        except (ValueError, OSError):
            return Receipt("readback_failed", "Backup retained; no keymap was written.")
        return self._write_verified(backup["original_json"], backup["original_digest"],
                                    "keymap_restored", expected_current=current_raw)
