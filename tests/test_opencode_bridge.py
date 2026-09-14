"""The OpenCode bridge: capability probing against a fake /doc."""

import json
import urllib.error

from jrbar.opencode_bridge import list_sessions, probe_capabilities


class _FakeResponse:
    def __init__(self, payload):
        self._data = json.dumps(payload).encode("utf-8")

    def read(self):
        return self._data

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _opener_for(doc=None, sessions=None):
    def open_(url, timeout=None):
        if url.endswith("/doc"):
            if doc is None:
                raise urllib.error.URLError("connection refused")
            return _FakeResponse(doc)
        if url.endswith("/session"):
            if sessions is None:
                raise urllib.error.URLError("connection refused")
            return _FakeResponse(sessions)
        raise urllib.error.URLError(f"unknown {url}")
    return open_


FULL_DOC = {"paths": {
    "/api/session/{sessionID}/interrupt": {},
    "/api/permission/{requestID}/reply": {},
    "/api/session/{sessionID}/question/{requestID}/reply": {},
    "/session": {},
    "/api/session/{sessionID}/event": {},
    "/api/session/{sessionID}/prompt": {},
}, "info": {"version": "1.18.30"}}


def test_probe_reports_the_served_surface():
    caps = probe_capabilities("http://127.0.0.1:4096",
                              opener=_opener_for(doc=FULL_DOC))
    assert caps.reachable is True
    assert caps.version == "1.18.30"
    assert caps.supported == frozenset(_CONTROL_KEYS)
    assert caps.missing == frozenset()


_CONTROL_KEYS = {"interrupt", "permission_reply", "question_reply",
                 "session_list", "session_events", "prompt"}


def test_probe_names_missing_operations():
    doc = {"paths": {"/session": {}}, "info": {"version": "1.0"}}
    caps = probe_capabilities("http://x", opener=_opener_for(doc=doc))
    assert caps.reachable is True
    assert "interrupt" in caps.missing
    assert "session_list" in caps.supported


def test_probe_unreachable_is_a_named_limitation():
    caps = probe_capabilities("http://x", opener=_opener_for(doc=None))
    assert caps.reachable is False
    assert caps.supported == frozenset()
    assert caps.reason == "opencode serve is not reachable"


def test_probe_malformed_doc_is_honest():
    caps = probe_capabilities("http://x",
                              opener=_opener_for(doc={"not": "openapi"}))
    assert caps.reachable is True
    assert caps.reason == "/doc answered without an OpenAPI paths map"


def test_list_sessions_projects_the_facts():
    sessions = [{
        "id": "ses_1", "title": "fix the bug", "directory": "/repo",
        "version": "1.18.30",
        "time": {"updated": 1700000000000},
        "transcript": "must not leak",
    }, {"no_id": True}, "junk"]
    out = list_sessions("http://x", opener=_opener_for(sessions=sessions))
    assert len(out) == 1
    assert out[0]["id"] == "ses_1"
    assert out[0]["title"] == "fix the bug"
    assert "transcript" not in out[0]


def test_list_sessions_unreachable_is_empty_not_fabricated():
    assert list_sessions("http://x", opener=_opener_for(sessions=None)) == []
