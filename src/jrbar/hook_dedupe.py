"""Cross-process duplicate suppression for normalized provider hook events."""

from __future__ import annotations

import fcntl
import json
import os
import stat
import threading
from collections.abc import Callable
from pathlib import Path

_STATE_VERSION = 1
_MAX_STATE_BYTES = 64 * 1024
_MAX_TOKEN_BYTES = 1024


class HookEventDeduplicator:
    def __init__(self, path: Path, *, max_tokens: int = 128) -> None:
        self.path = Path(path).expanduser()
        if type(max_tokens) is not int or not 1 <= max_tokens <= 4096:
            raise ValueError("max_tokens must be between 1 and 4096")
        self.max_tokens = max_tokens

    @staticmethod
    def _valid_token(token: object) -> bool:
        if not isinstance(token, str) or not token:
            return False
        encoded = token.encode("utf-8", errors="strict")
        return (
            len(encoded) <= _MAX_TOKEN_BYTES
            and "\x00" not in token
            and all(ord(character) >= 32 for character in token)
        )

    def _open(self) -> int:
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            os.chmod(self.path.parent, 0o700)
        except OSError:
            pass
        flags = os.O_RDWR | os.O_CREAT
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(self.path, flags, 0o600)
        info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or info.st_uid != os.getuid()
        ):
            os.close(descriptor)
            raise OSError("unsafe hook dedupe state file")
        if stat.S_IMODE(info.st_mode) != 0o600:
            os.fchmod(descriptor, 0o600)
        return descriptor

    @staticmethod
    def _read_locked(descriptor: int) -> list[str]:
        size = os.fstat(descriptor).st_size
        if size < 0 or size > _MAX_STATE_BYTES:
            return []
        os.lseek(descriptor, 0, os.SEEK_SET)
        raw = os.read(descriptor, _MAX_STATE_BYTES + 1)
        if len(raw) > _MAX_STATE_BYTES or not raw:
            return []
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return []
        if not isinstance(payload, dict) or payload.get("version") != _STATE_VERSION:
            return []
        values = payload.get("tokens")
        if not isinstance(values, list):
            return []
        result: list[str] = []
        for value in values:
            if HookEventDeduplicator._valid_token(value) and value not in result:
                result.append(value)
        return result

    @staticmethod
    def _write_locked(descriptor: int, tokens: list[str], *, sync: bool = True) -> None:
        payload = json.dumps(
            {"version": _STATE_VERSION, "tokens": tokens},
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        if len(payload) > _MAX_STATE_BYTES:
            raise OSError("hook dedupe state exceeds size limit")
        os.lseek(descriptor, 0, os.SEEK_SET)
        os.write(descriptor, payload)
        os.ftruncate(descriptor, len(payload))
        if sync:
            os.fsync(descriptor)

    def run_once(self, event_token: str, callback: Callable[[], object]) -> bool:
        if not self._valid_token(event_token):
            return False
        if not callable(callback):
            raise TypeError("callback must be callable")
        descriptor = self._open()
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            tokens = self._read_locked(descriptor)
            if event_token in tokens:
                return False
            callback()
            tokens.append(event_token)
            if len(tokens) > self.max_tokens:
                tokens = tokens[-self.max_tokens :]
            self._write_locked(descriptor, tokens)
            return True
        finally:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)

    def accept(self, event_token: str) -> bool:
        return self.run_once(event_token, lambda: None)

    def tokens(self) -> tuple[str, ...]:
        if not self.path.exists():
            return ()
        descriptor = self._open()
        try:
            fcntl.flock(descriptor, fcntl.LOCK_SH)
            return tuple(self._read_locked(descriptor))
        finally:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)


class ResidentHookDeduplicator(HookEventDeduplicator):
    """The daemon's deduplicator for one dedupe file.

    The standalone hook opens, locks, reads, rewrites and fsyncs the file for
    every event, and the next open of a file just written waits on the
    virus scanner (2.8 to 50 ms at p50 on this Mac). The daemon handles
    every live hook, so it keeps the file open and the tokens in memory. The
    file stays the backing store the standalone hook and the drainer share:
    it is still locked for every check, reread whenever another process
    changed it, and rewritten after each new token -- without an fsync, as
    the log append's own fsync is the durability point. A crash can lose
    the last tokens; a replay of that one event is then ordered out by its
    watermark.
    """

    def __init__(self, path: Path, *, max_tokens: int = 128) -> None:
        super().__init__(path, max_tokens=max_tokens)
        self._lock = threading.Lock()
        self._descriptor: int | None = None
        self._tokens: list[str] | None = None
        self._seen: tuple[int, int] | None = None

    def _held(self) -> int:
        """The open descriptor; reopened when the file was removed or
        replaced under it."""
        descriptor = self._descriptor
        if descriptor is not None:
            try:
                on_disk = os.stat(self.path, follow_symlinks=False)
                held = os.fstat(descriptor)
                if (on_disk.st_dev, on_disk.st_ino) == (held.st_dev, held.st_ino):
                    return descriptor
            except OSError:
                pass
            self.close()
        self._descriptor = self._open()
        self._tokens = None
        return self._descriptor

    def run_once(self, event_token: str, callback: Callable[[], object]) -> bool:
        if not self._valid_token(event_token):
            return False
        if not callable(callback):
            raise TypeError("callback must be callable")
        with self._lock:
            descriptor = self._held()
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            try:
                info = os.fstat(descriptor)
                if self._tokens is None or (info.st_size, info.st_mtime_ns) != self._seen:
                    # First use, or another process wrote the file since.
                    self._tokens = self._read_locked(descriptor)
                    self._seen = (info.st_size, info.st_mtime_ns)
                tokens = self._tokens
                if event_token in tokens:
                    return False
                callback()
                tokens.append(event_token)
                if len(tokens) > self.max_tokens:
                    del tokens[: len(tokens) - self.max_tokens]
                self._write_locked(descriptor, tokens, sync=False)
                info = os.fstat(descriptor)
                self._seen = (info.st_size, info.st_mtime_ns)
                return True
            finally:
                fcntl.flock(descriptor, fcntl.LOCK_UN)

    def close(self) -> None:
        descriptor, self._descriptor = self._descriptor, None
        self._tokens = None
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


class ResidentDeduplicators:
    """One resident deduplicator per dedupe file, for the daemon's ingress."""

    def __init__(self, *, max_tokens: int = 128) -> None:
        self._max_tokens = max_tokens
        self._lock = threading.Lock()
        self._by_path: dict[Path, ResidentHookDeduplicator] = {}

    def __call__(self, path: Path) -> ResidentHookDeduplicator:
        key = Path(path).expanduser()
        with self._lock:
            deduplicator = self._by_path.get(key)
            if deduplicator is None:
                deduplicator = ResidentHookDeduplicator(key, max_tokens=self._max_tokens)
                self._by_path[key] = deduplicator
            return deduplicator

    def close(self) -> None:
        with self._lock:
            held, self._by_path = list(self._by_path.values()), {}
        for deduplicator in held:
            deduplicator.close()


__all__ = ["HookEventDeduplicator", "ResidentDeduplicators", "ResidentHookDeduplicator"]
