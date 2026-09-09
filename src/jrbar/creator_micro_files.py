"""Bounded Creator Micro file transfer, separate from HID report fragmentation.

Interoperability reference: 00cyre/creator-micro-kit at a563b88c2dc251371dd4c670690a01f8980fc338.
No firmware/service methods are exposed. Call only from the sole device owner.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import re
import secrets
import time
from collections.abc import Callable

MAX_FILE_BYTES = 64 * 1024
READ_CHUNK = 1024
WRITE_CHUNK = 768  # Base64 plus envelope fits the normal bounded RPC budget.


class FileTransferError(ValueError):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


class CreatorMicroFiles:
    def __init__(self, adapter, *, is_current: Callable[[], bool] = lambda: True,
                 clock: Callable[[], float] = time.monotonic):
        self.adapter = adapter
        self.is_current = is_current
        self.clock = clock
        self.generation = getattr(adapter, "connection_generation", None)

    def _current(self) -> None:
        if not self.is_current():
            raise FileTransferError("cancelled")
        if not self.adapter.connected:
            raise FileTransferError("not_connected")
        if getattr(self.adapter, "connection_generation", None) != self.generation:
            raise FileTransferError("connection_changed")
        if getattr(getattr(self.adapter, "conflict", None), "active", False):
            raise FileTransferError("device_conflict")

    def rpc(self, method: str, params=None):
        self._current()
        receipt, reply = self.adapter._call(method, params)
        if receipt.code != "applied":
            if isinstance(reply, dict) and isinstance(reply.get("error"), dict):
                if reply["error"].get("code") in {-32601, 404}:
                    raise FileTransferError("unsupported_file_protocol")
            raise FileTransferError(receipt.code)
        if type(reply) is not dict:
            raise FileTransferError("malformed_report")
        self._current()
        return reply.get("result", reply.get("params"))

    @staticmethod
    def _name(name: str) -> None:
        if name != "keymap.json" and re.fullmatch(r"jrbar-probe-[0-9a-f]{12}\.json", name or "") is None:
            raise FileTransferError("file_not_allowed")

    def metadata(self, name: str) -> tuple[int, str]:
        self._name(name)
        try:
            value = self.rpc("fs.chksm", {"file": name})
        except FileTransferError as exc:
            if exc.code != "unsupported_file_protocol":
                raise
            entries = self.rpc("fs.list", {"checksum": True})
            if type(entries) is not list or len(entries) > 256:
                raise FileTransferError("malformed_file_list")
            matches = [entry for entry in entries if isinstance(entry, dict) and entry.get("name") == name]
            if len(matches) != 1:
                raise FileTransferError("file_not_found")
            value = matches[0]
        if (type(value) is not dict or type(value.get("size")) is not int
                or not 0 <= value["size"] <= MAX_FILE_BYTES
                or type(value.get("checksum")) is not str
                or re.fullmatch(r"[a-fA-F0-9]{40}", value["checksum"]) is None):
            raise FileTransferError("malformed_file_metadata")
        return value["size"], value["checksum"].lower()

    def read_bytes(self, name: str = "keymap.json") -> bytes:
        self._name(name)
        expected_size, expected_hash = self.metadata(name)
        result = bytearray()
        deadline = self.clock() + 90.0
        while len(result) < expected_size:
            if self.clock() > deadline:
                raise FileTransferError("file_transfer_timeout")
            value = self.rpc("fs.readbin", {"file": name, "offset": len(result), "len": READ_CHUNK})
            if (type(value) is not dict or type(value.get("total_size")) is not int
                    or value["total_size"] != expected_size or type(value.get("data")) is not str
                    or len(value["data"]) > 4 * ((READ_CHUNK + 2) // 3)):
                raise FileTransferError("malformed_file_chunk")
            try:
                chunk = base64.b64decode(value["data"], validate=True)
            except (ValueError, binascii.Error) as exc:
                raise FileTransferError("malformed_file_chunk") from exc
            if not chunk or len(chunk) > min(READ_CHUNK, expected_size - len(result)):
                raise FileTransferError("file_transfer_no_progress")
            result.extend(chunk)
        actual = bytes(result)
        if hashlib.sha1(actual).hexdigest() != expected_hash or self.metadata(name) != (expected_size, expected_hash):
            raise FileTransferError("file_changed_during_read")
        return actual

    def replace_bytes(self, name: str, raw: bytes, *, before_chunk: Callable[[int], None],
                      before_replace: Callable[[], None] = lambda: None) -> None:
        self._name(name)
        if type(raw) is not bytes or not 1 <= len(raw) <= MAX_FILE_BYTES:
            raise FileTransferError("invalid_file_size")
        deadline = self.clock() + 120.0
        self._current()
        entries = self.rpc("fs.list", {"checksum": True})
        if type(entries) is not list or len(entries) > 256:
            raise FileTransferError("malformed_file_list")
        matches = [entry for entry in entries if isinstance(entry, dict) and entry.get("name") == name]
        if len(matches) > 1:
            raise FileTransferError("malformed_file_list")
        before_replace()
        before_chunk(0)  # Durable recovery record must exist before deletion.
        self._current()
        if matches:
            self.rpc("fs.delete", {"file": name})
        for offset in range(0, len(raw), WRITE_CHUNK):
            if self.clock() > deadline:
                raise FileTransferError("file_transfer_timeout")
            chunk = raw[offset:offset + WRITE_CHUNK]
            before_chunk(offset + len(chunk))  # Also covers a lost acknowledgement.
            self.rpc("fs.writebin", {"file": name, "data": base64.b64encode(chunk).decode("ascii"),
                                     "append": True, "completed": offset + len(chunk) == len(raw),
                                     "offset": offset})
        if self.read_bytes(name) != raw:
            raise FileTransferError("readback_mismatch")

    def verify_write_protocol(self) -> None:
        """Verify binary writing on a uniquely named scratch file before keymap deletion."""
        name = f"jrbar-probe-{secrets.token_hex(6)}.json"
        entries = self.rpc("fs.list", {"checksum": True})
        if type(entries) is not list or len(entries) > 256:
            raise FileTransferError("malformed_file_list")
        if any(isinstance(entry, dict) and entry.get("name") == name for entry in entries):
            raise FileTransferError("scratch_file_collision")
        raw = b'{"jrbar":"file-transfer-probe"}\n'
        # New scratch files need no delete; no existing file can be overwritten.
        try:
            self.rpc("fs.writebin", {"file": name, "data": base64.b64encode(raw).decode("ascii"),
                                     "append": True, "completed": True, "offset": 0})
            if self.read_bytes(name) != raw:
                raise FileTransferError("readback_mismatch")
        finally:
            # Never use a reconnect to continue a prior operation. A failure
            # leaves only the named scratch file, not a partially changed keymap.
            self.rpc("fs.delete", {"file": name})
