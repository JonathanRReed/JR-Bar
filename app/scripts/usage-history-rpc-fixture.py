"""Temporary synthetic history service for the opt-in native round trip."""

import argparse
import tempfile
import threading
from pathlib import Path
from types import SimpleNamespace


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", type=Path, required=True)
    args = parser.parse_args()
    socket_path = args.socket.resolve()
    roots = (Path("/tmp").resolve(), Path(tempfile.gettempdir()).resolve())
    if (socket_path.name != "s" or not socket_path.parent.name.startswith("jrbar-history-")
            or not any(socket_path.is_relative_to(root) for root in roots)):
        parser.error("the fixture requires a private temporary socket named s")
    from jrbar.core_runtime import _cmd_usage_history
    from jrbar.core_server import CoreServer
    from jrbar.core_usage_history import UsageHistoryService

    gate = threading.Event()
    fail = [True]
    stamp = [1_800_000_000.0]
    counts = {"reads": 0, "observations": 0, "scans": 0}
    guard = threading.Lock()
    server = None

    def scan(provider, _days):
        with guard:
            counts["scans"] += 1
        if not gate.wait(30):
            raise TimeoutError("synthetic scan gate timed out")
        if fail[0]:
            raise OSError("synthetic private scan failure")
        return [(provider, "synthetic.session", "claude-sonnet-4-5", 1_800_000_000.0,
                 100, 0, 0, 20, "synthetic.record")]

    def publish(kind, **fields):
        if server is not None:
            server.publish_event({"kind": kind, **fields})

    service = UsageHistoryService(scan, publish, clock=lambda: stamp[0],
                                 wall_clock=lambda: stamp[0], codex_default_model=lambda: None)
    owner = SimpleNamespace(_core_lock=threading.RLock(), _core_documents={},
                            _core_usage_history_service=service)

    def dispatch(name, fields):
        if name == "fixture_release_failure":
            gate.set()
            return {"released": True}
        if name == "fixture_allow_success":
            fail[0] = False
            return {"allowed": True}
        if name == "fixture_prepare_refresh":
            gate.clear()
            stamp[0] += 61
            return {"prepared": True}
        if name == "fixture_counts":
            with guard:
                return dict(counts)
        if name == "usage_history":
            with guard:
                counts["observations" if fields.get("observe") else "reads"] += 1
            return _cmd_usage_history(owner, fields)
        raise ValueError("unexpected synthetic command")

    documents = [
        {"t": "state", "v": 1, "generation": 1, "sessions": [],
         "usage": {"providers": [{"id": "claude", "state": "ready", "windows": []}]}},
        {"t": "settings", "v": 1, "generation": 1, "document": {"usage_graph_days": 7}},
    ]
    server = CoreServer(dispatch=dispatch, initial_documents=lambda: documents, socket_path=socket_path)
    try:
        server.start()
        threading.Event().wait(60)
    finally:
        gate.set()
        service.close()
        server.stop()


if __name__ == "__main__":
    main()
