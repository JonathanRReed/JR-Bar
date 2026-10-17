"""Serve synthetic Usage Center data for native activation timing."""

from __future__ import annotations

import argparse
import re
import tempfile
import threading
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

EPOCH = 1_800_000_000.0
SOCKET_PARENT = re.compile(r"jrbar-activation-[0-9a-fA-F-]{36}\Z")


def _socket_path(value: Path) -> Path:
    socket_path = value.resolve()
    roots = (Path("/tmp").resolve(), Path(tempfile.gettempdir()).resolve())
    parent = socket_path.parent
    try:
        uuid.UUID(parent.name.removeprefix("jrbar-activation-"))
    except (ValueError, AttributeError):
        valid_name = False
    else:
        valid_name = SOCKET_PARENT.fullmatch(parent.name) is not None
    if (
        socket_path.name != "s"
        or not valid_name
        or not any(socket_path.is_relative_to(root) for root in roots)
    ):
        raise ValueError("the fixture requires /tmp/jrbar-activation-UUID/s")
    return socket_path


def _records(days: int) -> list[tuple]:
    latest = datetime.fromtimestamp(EPOCH)
    return [
        (
            "claude",
            "synthetic.session",
            "claude-sonnet-4-5",
            (latest - timedelta(days=offset)).timestamp(),
            100,
            0,
            0,
            20,
            f"synthetic.record.{offset}",
        )
        for offset in range(days)
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--days", type=int, choices=(7, 365), default=365)
    args = parser.parse_args()
    try:
        socket_path = _socket_path(args.socket)
    except ValueError as error:
        parser.error(str(error))

    from jrbar.core_runtime import _cmd_usage_history
    from jrbar.core_server import CoreServer
    from jrbar.core_usage_history import UsageHistoryService

    rows = _records(args.days)
    counts = {"reads": 0, "observations": 0, "scans": 0}
    guard = threading.RLock()
    service_lock = threading.RLock()
    server = None

    def scan(_provider: str, _days: int) -> list[tuple]:
        with guard:
            counts["scans"] += 1
        return rows

    def make_service() -> UsageHistoryService:
        return UsageHistoryService(
            scan,
            lambda kind, **fields: (
                server.publish_event({"kind": kind, **fields}) if server is not None else None
            ),
            clock=lambda: EPOCH,
            wall_clock=lambda: EPOCH,
            codex_default_model=lambda: None,
        )

    service = make_service()
    owner = SimpleNamespace(
        _core_lock=threading.RLock(),
        _core_documents={},
        _core_usage_history_service=service,
    )

    def dispatch(name, fields):
        nonlocal service
        if name == "usage_history":
            with guard:
                counts["observations" if fields.get("observe") else "reads"] += 1
            with service_lock:
                return _cmd_usage_history(owner, fields)
        if name == "fixture_warm":
            range_name = f"{args.days}d"
            with service_lock:
                document = service.document("claude", range_name, budget=5.0)
            ready = not document["pending"] and not document["stale"]
            return {
                "ready": ready,
                "pending": document["pending"],
                "stale": document["stale"],
                "records": document["records"],
            }
        if name == "fixture_counts":
            with guard:
                return dict(counts)
        if name == "fixture_reset_cache":
            with service_lock:
                service.close()
                service = make_service()
                owner._core_usage_history_service = service
            return {"reset": True}
        raise ValueError("unexpected synthetic command")

    documents = [
        {
            "t": "state",
            "v": 1,
            "generation": 1,
            "sessions": [],
            "usage": {
                "providers": [
                    {
                        "id": "claude",
                        "state": "ready",
                        "windows": [],
                    }
                ]
            },
        },
        {
            "t": "settings",
            "v": 1,
            "generation": 1,
            "document": {"usage_graph_days": args.days},
        },
    ]
    server = CoreServer(
        dispatch=dispatch,
        initial_documents=lambda: documents,
        socket_path=socket_path,
    )
    try:
        server.start()
        threading.Event().wait(120.0)
    finally:
        with service_lock:
            service.close()
        server.stop()


if __name__ == "__main__":
    main()
