"""The trie significance compare answers what the old path walk answered,
on synthetic document pairs shaped like the daemon's state and lights."""

from __future__ import annotations

import copy

from jrbar import core_runtime
from jrbar.core_runtime import _VOLATILE_DOC_PATHS, _equal_ignoring_volatile, doc_significant_equal


def _walk(kind: str, a, b) -> bool:
    """The path walk the trie replaced, kept as the reference."""
    return _equal_ignoring_volatile(a, b, (), _VOLATILE_DOC_PATHS.get(kind, ()))


def _state() -> dict:
    return {
        "t": "state",
        "now": 1000.0,
        "generation": 7,
        "sessions": [
            {"id": "claude:session:alpha", "mode": "working", "label": "Fix the build", "pid": 4242, "terminal": {"app": "Ghostty", "tty": "/dev/ttys001"}},
            {"id": "codex:session:beta", "mode": "waiting_for_input", "label": None, "pid": None, "terminal": None},
        ],
        "aggregate": {"working": 1, "asks": 1, "ready": 0},
        "health": {
            "sources": [
                {"key": "claude/hooks", "state": "live", "heard_age_seconds": 1.5},
                {"key": "codex/hooks", "state": "stale", "heard_age_seconds": 400.0},
            ],
            "intake": {"silence_seconds": 3.0, "ok": True},
        },
        "usage": {
            "providers": [
                {
                    "id": "claude",
                    "percent": 42,
                    "forecast": {"exhausts_at": 5000.0, "confidence": "low"},
                    "windows": [{"id": "5h", "used": 0.4, "forecast": {"exhausts_at": 5100.0, "pace": 1.2}}],
                }
            ]
        },
        "power": {"battery": {"percent": 80, "minutes_left": 300, "charging": False, "runway": {"minutes_left": 290, "note": "ok"}}},
        "devices": [{"id": "sidepulse", "write_health": {"latency_ms": 4.0, "writes": 10, "failing": False, "reason": None}}],
    }


def _lights() -> dict:
    return {
        "now": 1.0,
        "surfaces": [{"id": "strip", "program": "#112233", "why_detail": {"seconds_in_state": 4, "why": "working"}}],
        "auto_dim": {"lux": 20.0, "factor": 0.8, "reading": 21.0, "raw": 19.0, "mode": "ambient"},
        "dot_link": {"phase_error_ms": 0.4, "tolerance_ms": 20},
        "linked_skew_ms": 3.0,
    }


def _pairs():
    base = _state()

    def changed(mutate):
        doc = copy.deepcopy(base)
        mutate(doc)
        return doc

    yield "identical", "state", base, copy.deepcopy(base)
    yield "clock ticks", "state", base, changed(lambda d: d.update(now=1001.0, generation=8))
    yield "heard age ticks", "state", base, changed(lambda d: d["health"]["sources"][1].update(heard_age_seconds=401.0))
    yield "forecast moves", "state", base, changed(lambda d: d["usage"]["providers"][0]["forecast"].update(exhausts_at=4990.0))
    yield "window forecast moves", "state", base, changed(lambda d: d["usage"]["providers"][0]["windows"][0]["forecast"].update(exhausts_at=1.0))
    yield "window pace changes", "state", base, changed(lambda d: d["usage"]["providers"][0]["windows"][0]["forecast"].update(pace=2.0))
    yield "battery estimate drifts", "state", base, changed(lambda d: d["power"]["battery"].update(minutes_left=299))
    yield "runway drifts", "state", base, changed(lambda d: d["power"]["battery"]["runway"].update(minutes_left=1))
    yield "runway note changes", "state", base, changed(lambda d: d["power"]["battery"]["runway"].update(note="low"))
    yield "battery percent steps", "state", base, changed(lambda d: d["power"]["battery"].update(percent=79))
    yield "write latency drifts", "state", base, changed(lambda d: d["devices"][0]["write_health"].update(latency_ms=9.0, writes=11))
    yield "a device starts failing", "state", base, changed(lambda d: d["devices"][0]["write_health"].update(failing=True))
    yield "a session changes mode", "state", base, changed(lambda d: d["sessions"][0].update(mode="tool_running"))
    yield "a session appears", "state", base, changed(lambda d: d["sessions"].append({"id": "x", "mode": "working"}))
    yield "a terminal tty changes", "state", base, changed(lambda d: d["sessions"][0]["terminal"].update(tty="/dev/ttys002"))
    yield "a source changes state", "state", base, changed(lambda d: d["health"]["sources"][0].update(state="stale"))
    yield "a source appears", "state", base, changed(lambda d: d["health"]["sources"].append({"key": "pi", "heard_age_seconds": 1.0}))
    yield "a volatile key goes missing", "state", base, changed(lambda d: d["health"]["sources"][0].pop("heard_age_seconds"))
    yield "a significant key goes missing", "state", base, changed(lambda d: d["health"]["sources"][0].pop("state"))
    yield "the clock key goes missing", "state", base, changed(lambda d: d.pop("now"))
    yield "intake silence ticks", "state", base, changed(lambda d: d["health"]["intake"].update(silence_seconds=9.0))
    yield "intake goes bad", "state", base, changed(lambda d: d["health"]["intake"].update(ok=False))
    yield "a list becomes a tuple", "state", base, changed(lambda d: d.update(sessions=tuple(d["sessions"])))
    yield "a list becomes a dict", "state", base, changed(lambda d: d.update(sessions={"0": d["sessions"][0]}))
    yield "a volatile leaf changes type", "state", base, changed(lambda d: d.update(now=1000))
    yield "an unknown kind compares whole", "other", base, changed(lambda d: d.update(now=2.0))
    lights = _lights()
    yield "lights identical", "lights", lights, copy.deepcopy(lights)
    yield "lights sensor drifts", "lights", lights, {**copy.deepcopy(lights), "auto_dim": {**lights["auto_dim"], "lux": 1.0, "raw": 2.0}}
    yield "lights mode changes", "lights", lights, {**copy.deepcopy(lights), "auto_dim": {**lights["auto_dim"], "mode": "fixed"}}
    yield "lights seconds in state tick", "lights", lights, {
        **copy.deepcopy(lights),
        "surfaces": [{**lights["surfaces"][0], "why_detail": {"seconds_in_state": 5, "why": "working"}}],
    }
    yield "lights program changes", "lights", lights, {**copy.deepcopy(lights), "surfaces": [{**lights["surfaces"][0], "program": "#000000"}]}
    yield "phase error drifts", "lights", lights, {**copy.deepcopy(lights), "dot_link": {"phase_error_ms": 0.9, "tolerance_ms": 20}}


def test_the_trie_agrees_with_the_path_walk_on_every_fixture_pair() -> None:
    results = {}
    for label, kind, a, b in _pairs():
        expected = _walk(kind, a, b)
        assert doc_significant_equal(kind, a, b) == expected, label
        assert doc_significant_equal(kind, b, a) == _walk(kind, b, a), label
        results[label] = expected
    # The fixtures exercise both answers.
    assert results["clock ticks"] and results["battery estimate drifts"] and results["lights sensor drifts"]
    assert not results["a session changes mode"] and not results["a significant key goes missing"]
    assert results["a list becomes a tuple"] and not results["a list becomes a dict"]
    assert results["a volatile leaf changes type"], "a volatile value is ignored whatever its type"


def test_a_numeric_type_change_alone_is_equal_outside_volatile_branches() -> None:
    """The one documented difference: inside a mapping or list no volatile
    path runs through, numbers compare by value. A value compared on its
    own keeps its type."""
    a = _state()
    b = copy.deepcopy(a)
    b["aggregate"]["working"] = 1.0
    assert _walk("state", a, b) is False
    assert doc_significant_equal("state", a, b) is True
    c = copy.deepcopy(a)
    c["power"]["battery"]["percent"] = 80.0
    assert doc_significant_equal("state", a, c) is False, "compared on its own, under a volatile branch"
    d = copy.deepcopy(a)
    d["aggregate"]["working"] = 2
    assert doc_significant_equal("state", a, d) is False


def test_the_trie_is_built_once_per_kind() -> None:
    assert set(core_runtime._VOLATILE_TRIES) == set(_VOLATILE_DOC_PATHS)
