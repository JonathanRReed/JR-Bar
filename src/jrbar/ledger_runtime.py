"""Latest-wins background publication for the optional remote ledger."""

from __future__ import annotations

import threading
from collections.abc import Callable
from dataclasses import dataclass, replace
from pathlib import Path

from .remote_peers import RemotePeerSettings, publication_settings

LEDGER_PUBLISH_REASON_FAILED = "remote_ledger_publish_failed"
LEDGER_PUBLISH_REASON_REVOKED = "remote_ledger_publish_revoked"


@dataclass(frozen=True, slots=True)
class LedgerPublishRequest:
    generation: int
    statuses: tuple[object, ...]
    generated_at: object | None
    settings: object
    signature: object


@dataclass(frozen=True, slots=True)
class LedgerPublishResult:
    request: LedgerPublishRequest
    path: Path | None
    reason: str | None = None

    @property
    def accepted(self) -> bool:
        return self.reason is None


class RemoteLedgerPublisher:
    def __init__(
        self,
        publish: Callable[..., Path | None],
        *,
        settings_supplier: Callable[[], RemotePeerSettings] | None = None,
    ) -> None:
        if not callable(publish):
            raise ValueError("ledger publisher must be callable")
        self._publish = publish
        self._settings_supplier = settings_supplier
        self._lock = threading.RLock()
        self._generation = 0
        self._closed = False
        self._in_flight = False
        self._pending: tuple[
            LedgerPublishRequest,
            Callable[[LedgerPublishResult], None],
        ] | None = None

    def request(
        self,
        *,
        statuses: tuple[object, ...],
        generated_at: object | None,
        settings: object,
        signature: object,
        callback: Callable[[LedgerPublishResult], None],
    ) -> int | None:
        if type(statuses) is not tuple or not callable(callback):
            raise ValueError("invalid ledger publication request")
        with self._lock:
            if self._closed:
                return None
            if self._settings_supplier is not None:
                settings = publication_settings(settings, self._settings_supplier)
                if settings is None:
                    return None
            self._generation += 1
            request = LedgerPublishRequest(
                self._generation,
                statuses,
                generated_at,
                settings,
                signature,
            )
            if self._in_flight:
                self._pending = (request, callback)
            else:
                self._start_locked(request, callback)
            return request.generation

    def close(self) -> None:
        with self._lock:
            self._closed = True
            self._generation += 1
            self._pending = None

    def _start_locked(
        self,
        request: LedgerPublishRequest,
        callback: Callable[[LedgerPublishResult], None],
    ) -> None:
        self._in_flight = True
        threading.Thread(
            target=self._run,
            args=(request, callback),
            name="JRBarRemoteLedgerPublish",
            daemon=True,
        ).start()

    def _run(
        self,
        request: LedgerPublishRequest,
        callback: Callable[[LedgerPublishResult], None],
    ) -> None:
        try:
            with self._lock:
                settings = None if self._closed else request.settings
                if settings is not None and self._settings_supplier is not None:
                    settings = publication_settings(settings, self._settings_supplier)
            if settings is None:
                result = LedgerPublishResult(request, None, LEDGER_PUBLISH_REASON_REVOKED)
            else:
                request = replace(request, settings=settings)
                options = {}
                if self._settings_supplier is not None:
                    options["settings_supplier"] = self._settings_supplier
                path = self._publish(
                    request.statuses,
                    generated_at=request.generated_at,
                    settings=settings,
                    **options,
                )
                result = LedgerPublishResult(request, path)
        except Exception:
            result = LedgerPublishResult(
                request,
                None,
                LEDGER_PUBLISH_REASON_FAILED,
            )
        accepted_callback = None
        with self._lock:
            current = not self._closed and request.generation == self._generation
            self._in_flight = False
            if current:
                accepted_callback = callback
            if not self._closed and self._pending is not None:
                pending_request, pending_callback = self._pending
                self._pending = None
                self._start_locked(pending_request, pending_callback)
        if accepted_callback is not None:
            try:
                accepted_callback(result)
            except Exception:
                pass
